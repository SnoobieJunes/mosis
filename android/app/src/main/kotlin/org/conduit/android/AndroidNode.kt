package org.conduit.android

import android.content.Context
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import org.conduit.android.transport.DiscoveredPeer
import org.conduit.android.transport.LanTransport
import org.conduit.android.transport.TlsMaterial
import org.conduit.core.identity.Identity
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
    val toast = MutableStateFlow<String?>(null)
    var confirmPairing: (suspend (PairPrompt) -> Boolean)? = null
    var pairingEnabled = false

    private val discoveredMap = ConcurrentHashMap<String, DiscoveredPeer>()

    fun start() {
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
        add(Proto.CAP_FILE); add(Proto.CAP_CLIPBOARD); add(Proto.CAP_SCREEN_SOURCE); add(Proto.CAP_NOTIFY_SHOW)
        if (canReceiveInput) add(Proto.CAP_INPUT_INJECT)
        if (canSourceNotifications) add(Proto.CAP_NOTIFY_SOURCE)
    }

    // --- inbound routing ---

    private suspend fun routeInbound(conn: FramedConnection) {
        val first = conn.nextFrame() as? Frame.Control ?: return conn.close()
        val (env, msg) = MessageCodec.decode(first.payload)
        when (msg.type) {
            MessageType.HELLO -> adoptSession(conn, msg.payload, env.sessionId)
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
        runReadLoop(conn, peer)
    }

    // --- outbound ---

    suspend fun pair(host: String, port: Int) {
        val stream = withContext(Dispatchers.IO) { transport.dial(host, port, LanTransport.PinPolicy { true }) }
        val conn = FramedConnection(stream)
        val outcome = PairingFlow.initiate(conn, local) { p -> confirmPairing?.invoke(p) ?: false }
        if (outcome is PairOutcome.Paired) pin(outcome.peer) else toast.value = "Pairing failed"
        conn.close()
    }

    suspend fun connect(peer: PinnedPeer, host: String, port: Int): FramedConnection? {
        val stream = withContext(Dispatchers.IO) { transport.dial(host, port, pinnedPolicy(peer)) }
        val conn = FramedConnection(stream)
        HelloFlow.initiate(conn, local, capabilities(), listenPort)
        links[peer.deviceId] = conn
        scope.launch { runReadLoop(conn, peer) }
        return conn
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
                        }
                    }
                    is Frame.Chunk -> receiver.handleChunk(conn, frame.frame)
                    else -> {}
                }
            }
        } catch (_: Exception) {
        } finally {
            links.remove(peer.deviceId)
        }
    }

    private fun pin(peer: PinnedPeer) {
        peers[peer.deviceId] = peer
        pinned.value = peers.values.toList()
        toast.value = "Paired with ${peer.name}"
    }

    fun listenPort() = listenPort
    fun peerFor(deviceId: String) = peers[deviceId]
    fun discoveredFor(serviceName: String) = discoveredMap[serviceName]
}
