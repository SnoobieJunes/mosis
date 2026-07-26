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
        transport.discover(
            onFound = { p -> if (p.deviceId != identity.deviceId) { discoveredMap[p.serviceName] = p; discovered.value = discoveredMap.values.toList() } },
            onLost = { name -> discoveredMap.remove(name); discovered.value = discoveredMap.values.toList() },
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
        val peer = peers.values.firstOrNull { it.tlsPubkeySha256.toHex() == keyHash } ?: return conn.close()
        HelloFlow.respond(conn, hello, sessionId, local, capabilities(), listenPort)
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
        val stream = try {
            transport.dial(host, port, LanTransport.PinPolicy { true })
        } catch (e: Exception) {
            toast.value = "Couldn't reach the device — are you on the same network?"
            return@withContext
        }
        val conn = FramedConnection(stream)
        val outcome = PairingFlow.initiate(conn, local) { p ->
            runBlocking { confirmPairing?.invoke(p) ?: false }
        }
        if (outcome is PairOutcome.Paired) pin(outcome.peer) else toast.value = "Pairing failed"
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
            HelloFlow.initiate(conn, local, capabilities(), listenPort)
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
                            MessageType.CLIPBOARD_PUSH -> ConduitRuntime.instance?.onClipboardReceived(String(msg.payload.asObj().getValue("data").bytes(), Charsets.UTF_8))
                            MessageType.FILE_OFFER -> receiver.handleOffer(conn, msg.payload)
                            MessageType.FILE_ACCEPT -> {
                                val fileId = msg.payload.asObj().getValue("file_id").str()
                                val resume = msg.payload.asObj().getValue("resume_from_chunk").long()
                                pendingSends[fileId]?.let { scope.launch(Dispatchers.IO) { FileSend.pump(conn, it, fileId, resume) } }
                            }
                            MessageType.NOTIFICATION -> ConduitRuntime.instance?.onNotificationReceived(msg.payload)
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
        } catch (_: Exception) {
        } finally {
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

    private val peersFile = File(receiveDir.parentFile ?: receiveDir, "peers.json")

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
    fun peerFor(deviceId: String) = peers[deviceId]
    fun discoveredFor(serviceName: String) = discoveredMap[serviceName]

    /** Lookup by device id — NSD service names can carry dedup suffixes, so
     *  matching a pinned peer by name is unreliable. */
    fun discoveredForDevice(deviceId: String): DiscoveredPeer? =
        discoveredMap.values.firstOrNull { it.deviceId == deviceId }
}
