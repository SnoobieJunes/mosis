package org.conduit.android

import android.content.Context
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.conduit.android.transport.DiscoveredPeer
import org.conduit.android.transport.LanTransport
import org.conduit.android.transport.TlsMaterial
import org.conduit.core.identity.Identity
import org.conduit.core.identity.fromHex
import org.conduit.core.identity.toHex
import org.conduit.core.session.*
import org.conduit.core.wire.*
import java.io.File
import java.util.concurrent.ConcurrentHashMap

/**
 * The Android node: wires the shared core session layer over the Android LAN
 * transport. This is the same pairing/HELLO/file logic proven by conformance +
 * the JVM session smoke — it just runs over real TLS sockets here, so an Android
 * peer interoperates with the iPhone, Mac, and Go daemon.
 */
class AndroidNode(
    private val context: Context,
    private val identity: Identity,
    private val material: TlsMaterial,
    private val name: String,
    private val receiveDir: File,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val transport = LanTransport(context, material)
    private val local = LocalIdentity(identity, name, "phone", material.publicKeyHash)
    private val peers = ConcurrentHashMap<String, PinnedPeer>()          // deviceId → peer
    private val links = ConcurrentHashMap<String, FramedConnection>()    // deviceId → live session
    private var listenPort = 0

    // Direction-specific capabilities are toggled on as the user enables the
    // matching Android service (input-inject when Accessibility is on, etc.).
    @Volatile var canReceiveInput = false
    @Volatile var canSourceNotifications = false

    val discovered = MutableStateFlow<List<DiscoveredPeer>>(emptyList())
    val pinned = MutableStateFlow<List<PinnedPeer>>(emptyList())
    /** Device ids with a live session — drives the Connected badge + actions. */
    val connected = MutableStateFlow<Set<String>>(emptySet())
    val toast = MutableStateFlow<String?>(null)
    var confirmPairing: (suspend (PairPrompt) -> Boolean)? = null
    var pairingEnabled = false

    private val discoveredMap = ConcurrentHashMap<String, DiscoveredPeer>()

    /** Screen sharing, both directions (AND-1 + AND-2). */
    val screens = org.conduit.android.capability.ScreenSessions(
        scope = scope,
        sendTo = { peerId, type, payload -> links[peerId]?.send(type, payload) },
        sendFrameTo = { peerId, frame -> links[peerId]?.sendScreenFrame(frame) },
        toast = { toast.value = it },
    )

    fun start() {
        loadPeers()
        val server = transport.listen(::listenerPolicy) { stream -> scope.launch { routeInbound(FramedConnection(stream)) } }
        listenPort = server.port
        transport.advertise(listenPort, identity.deviceId, name, "phone")
        Diag.log("start: listening on ${localAddress() ?: "?"}:$listenPort as $name (${deviceIdPrefix()}), ${peers.size} paired")
        transport.discover(
            onFound = { p ->
                if (p.deviceId != identity.deviceId) {
                    Diag.log("discover: found ${p.name} at ${p.host}:${p.port} (${p.deviceId?.take(8) ?: "no id in TXT"})")
                    discoveredMap[p.serviceName] = p; discovered.value = discoveredMap.values.toList()
                }
            },
            onLost = { name ->
                Diag.log("discover: lost $name")
                discoveredMap.remove(name); discovered.value = discoveredMap.values.toList()
            },
        )
    }

    private fun listenerPolicy(hex: String): Boolean =
        pairingEnabled || peers.values.any { it.tlsPubkeySha256.toHex() == hex }

    private fun pinnedPolicy(peer: PinnedPeer) = LanTransport.PinPolicy { it == peer.tlsPubkeySha256.toHex() }

    private fun capabilities(): List<String> = buildList {
        add(Proto.CAP_FILE); add(Proto.CAP_CLIPBOARD); add(Proto.CAP_NOTIFY_SHOW)
        // screen-view: there is a real MediaCodec decoder behind this now
        // (ScreenDecoder + ScreenViewerScreen), so the promise can be kept.
        add(Proto.CAP_SCREEN_VIEW)
        // screen-source: the MediaProjection path is wired end to end
        // (ScreenShareManager → ScreenProjectionSource → SCREEN_FRAME). It was
        // withdrawn while `ScreenProjectionSource` existed but nothing
        // instantiated it and the wire layer had no SCREEN_* builders — a
        // capability string is a promise, and advertising one the code can't
        // keep made the Mac offer "View this phone's screen" and then hand the
        // user a request that could never be answered. Both halves exist now.
        // Still device-unverified: see android/README.md.
        add(Proto.CAP_SCREEN_SOURCE)
        if (canReceiveInput) add(Proto.CAP_INPUT_INJECT)
        if (canSourceNotifications) add(Proto.CAP_NOTIFY_SOURCE)
    }

    // --- inbound routing ---

    private suspend fun routeInbound(conn: FramedConnection) {
        val first = conn.nextFrame() as? Frame.Control ?: return conn.close()
        val (env, msg) = MessageCodec.decode(first.payload)
        when (msg.type) {
            MessageType.HELLO -> adoptSession(conn, msg.payload, env.sessionId)
            // A source dialling back to stream video on a dedicated connection.
            // Without this branch the Mac's reverse-dial was answered with a
            // closed socket and every screen share fell back to the session
            // link — when it worked at all.
            MessageType.SCREEN_ATTACH -> screens.attachInboundLane(conn, msg.payload)
            MessageType.PAIR_REQUEST -> {
                if (!pairingEnabled) { conn.send(MessageType.PAIR_REJECT, Bodies.pairReject("pairing disabled")); conn.close(); return }
                val outcome = PairingFlow.respond(conn, msg.payload, env.sessionId, local) { p ->
                    runBlocking { confirmPairing?.invoke(p) ?: false }
                }
                if (outcome is PairOutcome.Paired) pin(outcome.peer)
                conn.close()
            }
            else -> conn.close()
        }
    }

    private fun adoptSession(conn: FramedConnection, hello: Json, sessionId: String) {
        val keyHash = conn.stream.peerTlsKeyHash?.toHex() ?: return conn.close()
        val peer = peers.values.firstOrNull { it.tlsPubkeySha256.toHex() == keyHash }
            ?: run {
                Diag.warn("inbound HELLO from an unpinned TLS key ${keyHash.take(16)} — refusing")
                return conn.close()
            }
        val caps = capabilities()
        Diag.log("session ${peer.name}: adopted inbound, advertising $caps")
        HelloFlow.respond(conn, hello, sessionId, local, caps, listenPort)
        links[peer.deviceId] = conn
        connected.value = links.keys.toSet()
        runReadLoop(conn, peer)
    }

    // --- outbound ---

    /// The whole ceremony runs on IO, not just the dial.
    ///
    /// `PairingFlow` is deliberately non-suspending — `core` has zero
    /// dependencies so it can be conformance-tested with a bare `kotlinc` — but
    /// the confirm callback has to wait for a human tapping a dialog, so it
    /// bridges with `runBlocking`, exactly as the responder path already did.
    /// Without `withContext(Dispatchers.IO)` around it that `runBlocking` would
    /// block the main thread waiting for a main-thread dialog: a deadlock.
    /// (The initiator path simply omitted the bridge and did not compile —
    /// nothing has ever built this module; CI compiles `core` only.)
    suspend fun pair(host: String, port: Int) = withContext(Dispatchers.IO) {
        Diag.log("pair: dialling $host:$port")
        val stream = try {
            transport.dial(host, port, LanTransport.PinPolicy { true })
        } catch (e: Exception) {
            // Keep the human sentence, but say what actually failed as well —
            // and log it. Before 2026-08-17 every dial failure looked identical
            // and nothing was written to logcat, so a tester whose pairing
            // failed had nothing to report.
            Diag.log("pair: dial failed — ${e.javaClass.simpleName}: ${e.message}")
            toast.value = "Couldn't reach $host:$port — are you on the same network? (${e.message ?: e.javaClass.simpleName})"
            return@withContext
        }
        Diag.log("pair: TLS up, peer key ${stream.peerTlsKeyHash?.toHex()?.take(16)}")
        val conn = FramedConnection(stream)
        val outcome = PairingFlow.initiate(conn, local) { p ->
            runBlocking { confirmPairing?.invoke(p) ?: false }
        }
        when (outcome) {
            is PairOutcome.Paired -> pin(outcome.peer)
            // PairOutcome.Failed carried a reason the UI threw away.
            is PairOutcome.Failed -> {
                Diag.log("pair: failed — ${outcome.reason}")
                toast.value = "Pairing failed: ${outcome.reason}"
            }
            PairOutcome.Declined -> {
                Diag.log("pair: declined on one side")
                toast.value = "Pairing cancelled — the codes have to match on both screens"
            }
        }
        conn.close()
    }

    /// Same IO-wrapping rule as `pair`: the HELLO exchange is blocking socket
    /// work, so the whole sequence stays off the main thread.
    suspend fun connect(peer: PinnedPeer, host: String, port: Int): FramedConnection? =
        withContext(Dispatchers.IO) {
            val stream = try {
                transport.dial(host, port, pinnedPolicy(peer))
            } catch (e: Exception) {
                toast.value = "Couldn't reach ${peer.name}"
                return@withContext null
            }
            val conn = FramedConnection(stream)
            val caps = capabilities()
            Diag.log("session ${peer.name}: connected outbound, advertising $caps")
            HelloFlow.initiate(conn, local, caps, listenPort)
            links[peer.deviceId] = conn
            connected.value = links.keys.toSet()
            scope.launch { runReadLoop(conn, peer) }
            conn
        }

    fun sendFile(peerId: String, path: File) {
        val conn = links[peerId] ?: return
        scope.launch {
            val fileId = FileSend.offer(conn, path)
            // FileSend.pump fires after the receiver's FILE_ACCEPT, handled in runReadLoop.
            pendingSends[fileId] = path
        }
    }

    fun sendClipboard(peerId: String, text: String) {
        links[peerId]?.send(MessageType.CLIPBOARD_PUSH, Bodies.clipboardText(text))
    }

    private val moveCoalescer = InputMoveCoalescer(scope) { peerId, dx, dy ->
        links[peerId]?.send(MessageType.INPUT_EVENT, Bodies.inputEventMove(dx, dy))
    }

    /** Motion is coalesced so a drag doesn't emit one wire frame per pointer sample. */
    fun sendInputMove(peerId: String, dx: Double, dy: Double) {
        moveCoalescer.move(peerId, dx, dy)
    }

    /** Left tap. Flushes pending motion first so the click lands where the
     *  cursor visibly is (same ordering contract as the Swift coalescer). */
    fun sendInputClick(peerId: String) {
        moveCoalescer.flush()
        links[peerId]?.send(MessageType.INPUT_EVENT, Bodies.inputEventClick())
    }

    fun sendInputClick(peerId: String, button: String, action: String = "tap") {
        moveCoalescer.flush()
        links[peerId]?.send(MessageType.INPUT_EVENT, Bodies.inputEventClick(button, action))
    }

    fun sendInputScroll(peerId: String, dx: Double, dy: Double) {
        moveCoalescer.flush()
        links[peerId]?.send(MessageType.INPUT_EVENT, Bodies.inputEventScroll(dx, dy))
    }

    /** Literal characters, or a named special key. Ordering matches motion. */
    fun sendInputKey(
        peerId: String, text: String? = null, key: String? = null,
        action: String? = null, modifiers: List<String> = emptyList(),
    ) {
        moveCoalescer.flush()
        links[peerId]?.send(MessageType.INPUT_EVENT, Bodies.inputEventKey(text, key, action, modifiers))
    }

    fun sendMediaControl(peerId: String, action: String, value: Double? = null) {
        links[peerId]?.send(MessageType.MEDIA_CONTROL, Bodies.mediaControl(action, value))
    }

    /** Asks a peer for control of it (INPUT_REQUEST). */
    fun requestInputControl(peerId: String) {
        links[peerId]?.send(MessageType.INPUT_REQUEST, Bodies.empty())
    }

    /** Mirror a notification to every peer advertising notify-show. */
    fun mirrorNotification(app: String, title: String, body: String, id: String) {
        val payload = Bodies.notification(app, title, body, id)
        links.values.forEach { it.send(MessageType.NOTIFICATION, payload) }
    }

    private val pendingSends = ConcurrentHashMap<String, File>()
    private val receivers = ConcurrentHashMap<String, FileReceive>()

    private fun runReadLoop(conn: FramedConnection, peer: PinnedPeer) {
        val receiver = FileReceive(receiveDir).apply { onComplete = { f, _ -> toast.value = "Received ${f.name}" } }
        receivers[peer.deviceId] = receiver
        try {
            while (true) {
                when (val frame = conn.nextFrame() ?: break) {
                    is Frame.Control -> {
                        val (_, msg) = MessageCodec.decode(frame.payload)
                        when (msg.type) {
                            // PING/PONG is normative (docs/protocol.md §Session
                            // behavior: 3 unanswered → degraded, 6 → close). This
                            // branch did not exist until 2026-08-17, so an Apple
                            // peer hung up on Android roughly 30 s after HELLO —
                            // the first thing anyone who got past pairing would
                            // have hit. Echo the nonce and t unchanged.
                            MessageType.PING -> {
                                val o = msg.payload.asObj()
                                conn.send(MessageType.PONG, Bodies.ping(o.getValue("nonce").str(), o.getValue("t").long()))
                            }
                            // We do not send PING yet, so a PONG is unexpected —
                            // named and ignored rather than falling through.
                            MessageType.PONG -> Unit
                            MessageType.CLIPBOARD_PUSH -> ConduitRuntime.instance?.onClipboardReceived(String(msg.payload.asObj().getValue("data").bytes(), Charsets.UTF_8))
                            MessageType.FILE_OFFER -> receiver.handleOffer(conn, msg.payload)
                            MessageType.FILE_ACCEPT -> {
                                val fileId = msg.payload.asObj().getValue("file_id").str()
                                val resume = msg.payload.asObj().getValue("resume_from_chunk").long()
                                pendingSends[fileId]?.let { scope.launch(Dispatchers.IO) { FileSend.pump(conn, it, fileId, resume) } }
                            }
                            // Outbound transfers were silent: complete, rejected
                            // and hash-mismatched all looked identical, and every
                            // send leaked its File in pendingSends (2026-08-17).
                            MessageType.FILE_ACK -> {
                                val o = msg.payload.asObj()
                                val fileId = o.getValue("file_id").str()
                                when (o.getValue("status").str()) {
                                    "progress" -> Unit
                                    "complete" -> { pendingSends.remove(fileId)?.let { toast.value = "Sent ${it.name}" } }
                                    else -> {
                                        val name = pendingSends.remove(fileId)?.name ?: "file"
                                        toast.value = "Send failed ($name): ${o.getValue("status").str()}"
                                    }
                                }
                            }
                            MessageType.FILE_REJECT -> {
                                val o = msg.payload.asObj()
                                val name = pendingSends.remove(o.getValue("file_id").str())?.name ?: "file"
                                toast.value = "Declined ($name)"
                            }
                            MessageType.NOTIFICATION -> ConduitRuntime.instance?.onNotificationReceived(msg.payload)
                            // Answer INPUT_REQUEST honestly either way. We
                            // advertise `input-inject` whenever the
                            // AccessibilityService is on but never replied until
                            // 2026-08-17, so a Mac controller sat through its
                            // 10 s timeout and reported "no response from peer".
                            // Consent posture matches conduitd: a standing grant
                            // for a paired peer (the pairing was the trust
                            // decision), gated on the service the user turned on.
                            MessageType.INPUT_REQUEST ->
                                if (canReceiveInput) {
                                    conn.send(MessageType.INPUT_STATUS, Bodies.inputStatus(true))
                                } else {
                                    conn.send(
                                        MessageType.INPUT_STATUS,
                                        Bodies.inputStatus(false, "MOSIS's accessibility service is off on this device — enable it in Settings ▸ Accessibility"),
                                    )
                                }
                            MessageType.INPUT_EVENT -> if (canReceiveInput) org.conduit.android.capability.InputAccessibilityService.instance?.inject(msg.payload)
                            // Phase 3 — screen sharing, both directions.
                            MessageType.SCREEN_OFFER -> screens.handleOffer(peer.deviceId, msg.payload)
                            MessageType.SCREEN_REQUEST -> screens.handleRequest(peer.deviceId)
                            MessageType.SCREEN_ACK -> screens.handleAck(msg.payload)
                            MessageType.SCREEN_END -> screens.handleEnd(peer.deviceId, msg.payload)
                            MessageType.SCREEN_REJECT -> screens.handleReject(msg.payload)
                        }
                    }
                    is Frame.Chunk -> receiver.handleChunk(conn, frame.frame)
                    // A screen frame on the SESSION link: the source could not
                    // dial a dedicated lane back to this phone and is streaming
                    // over the connection that already works. These used to be
                    // dropped on the floor, which is a large part of why the app
                    // could not view a Mac at all.
                    is Frame.Screen -> screens.handleControlLaneFrame(peer.deviceId, frame.frame)
                }
            }
        } catch (e: Exception) {
            // Swallowed silently until 2026-08-17, so a session that died mid-way
            // — a framing error, a closed socket, an unparsable body — looked
            // exactly like a peer walking out of Wi-Fi range.
            Diag.warn("session ${peer.name}: read loop ended — ${e.javaClass.simpleName}: ${e.message}")
        } finally {
            Diag.log("session ${peer.name}: closed")
            links.remove(peer.deviceId)
            connected.value = links.keys.toSet()
            screens.handleSessionClosed(peer.deviceId)
        }
    }

    private fun pin(peer: PinnedPeer) {
        peers[peer.deviceId] = peer
        pinned.value = peers.values.toList()
        savePeers()
        toast.value = "Paired with ${peer.name}"
    }

    fun unpair(deviceId: String) {
        peers.remove(deviceId)
        links.remove(deviceId)?.close()
        pinned.value = peers.values.toList()
        savePeers()
    }

    // --- pinned-peer persistence -------------------------------------------
    //
    // The pinning database was an in-memory map, so every app kill forgot every
    // pairing while the *other* side kept pinning this device — the asymmetry
    // that presents as "it paired fine yesterday and now refuses to connect".
    // Stored as one canonical-JSON line per peer in the app's private files dir;
    // deliberately boring (spec §9 Phase 1 step 4: "SwiftData or flat file, keep
    // it boring").

    // Internal storage, alongside the identity it belongs with — which is what
    // the comment above always claimed. Until 2026-08-17 this was
    // `receiveDir.parentFile`, i.e. app-specific *external* storage: the pinned
    // peer database sat next to the downloads folder while the Ed25519 seed and
    // TLS key lived in filesDir, and if external storage was unavailable
    // getExternalFilesDir(null) returned null, so the path degraded to a root
    // the app cannot write and every pairing failed with "Couldn't save
    // pairing". Old files are migrated once, below.
    private val peersFile = File(File(context.filesDir, "conduit").apply { mkdirs() }, "peers.json")

    /** One-time move of a pre-2026-08-17 peers.json out of external storage. */
    private fun migrateLegacyPeersFile() {
        if (peersFile.exists()) return
        val legacy = File(receiveDir.parentFile ?: receiveDir, "peers.json")
        if (!legacy.exists()) return
        try {
            legacy.copyTo(peersFile, overwrite = true)
            legacy.delete()
        } catch (e: Exception) {
            toast.value = "Couldn't move saved pairings: ${e.message}"
        }
    }

    private fun savePeers() {
        try {
            val lines = peers.values.map { p ->
                listOf(
                    p.deviceId,
                    p.name.replace('\t', ' '),
                    p.deviceClass,
                    p.ed25519Pubkey.toHex(),
                    p.tlsPubkeySha256.toHex(),
                ).joinToString("\t")
            }
            peersFile.writeText(lines.joinToString("\n"))
        } catch (e: Exception) {
            toast.value = "Couldn't save pairing: ${e.message}"
        }
    }

    private fun loadPeers() {
        migrateLegacyPeersFile()
        if (!peersFile.exists()) return
        try {
            peersFile.readLines().filter { it.isNotBlank() }.forEach { line ->
                val f = line.split('\t')
                if (f.size == 5) {
                    peers[f[0]] = PinnedPeer(f[0], f[1], f[2], f[3].fromHex(), f[4].fromHex())
                }
            }
            pinned.value = peers.values.toList()
        } catch (e: Exception) {
            toast.value = "Couldn't read saved pairings: ${e.message}"
        }
    }

    fun listenPort() = listenPort

    /** First 8 hex of this device's id — enough to match against a peer's log. */
    fun deviceIdPrefix(): String = identity.deviceId.take(8)

    /**
     * Best-guess LAN address of this device.
     *
     * Added 2026-08-17 for the "This device" line. Without it there was no way
     * to pair with anything that does not advertise over mDNS — and `conduitd`
     * does not advertise at all — because nothing in the UI or the logs ever
     * revealed the address and port a peer would have to dial. `listenPort()`
     * existed and had no callers for the same reason.
     */
    fun localAddress(): String? = try {
        java.net.NetworkInterface.getNetworkInterfaces().toList()
            .asSequence()
            .filter { it.isUp && !it.isLoopback }
            .flatMap { it.inetAddresses.toList().asSequence() }
            .filterIsInstance<java.net.Inet4Address>()
            .firstOrNull { !it.isLinkLocalAddress }
            ?.hostAddress
    } catch (_: Exception) {
        null
    }

    fun peerFor(deviceId: String) = peers[deviceId]
    fun discoveredFor(serviceName: String) = discoveredMap[serviceName]

    /** Lookup by device id — NSD service names can carry dedup suffixes, so
     *  matching a pinned peer by name is unreliable. */
    fun discoveredForDevice(deviceId: String): DiscoveredPeer? =
        discoveredMap.values.firstOrNull { it.deviceId == deviceId }
}
