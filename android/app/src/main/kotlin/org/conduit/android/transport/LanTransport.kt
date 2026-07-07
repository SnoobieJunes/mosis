package org.conduit.android.transport

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import org.conduit.core.session.ByteStream
import org.conduit.core.wire.Proto
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.security.cert.X509Certificate
import javax.net.ssl.*

/**
 * Android LAN backend (spec §9 Phase 5 step 2): NSD discovery + TLS 1.3 sockets
 * with mandatory mutual certificates verified by pinned public-key hash only.
 * No plaintext path — same invariant as the Swift/Go backends. Provides a
 * [ByteStream] to the shared core session layer, so pairing/HELLO/file logic is
 * exactly the code the conformance + smoke tests exercised.
 */
class LanTransport(
    private val context: Context,
    private val material: TlsMaterial,
) {
    fun interface PinPolicy {
        /** Return true if the presented peer key hash is acceptable. */
        fun allows(peerKeyHashHex: String): Boolean
    }

    private val nsd get() = context.getSystemService(Context.NSD_SERVICE) as NsdManager

    // --- TLS wiring: pinning replaces chain validation, both directions ---

    private fun sslContext(policy: PinPolicy): SSLContext {
        val keyManagers = arrayOf<KeyManager>(SingleCertKeyManager(material))
        val trustManagers = arrayOf<TrustManager>(PinningTrustManager(policy))
        return SSLContext.getInstance("TLSv1.3").apply {
            init(keyManagers, trustManagers, java.security.SecureRandom())
        }
    }

    fun dial(host: String, port: Int, policy: PinPolicy): ByteStream {
        val ctx = sslContext(policy)
        val socket = ctx.socketFactory.createSocket(InetAddress.getByName(host), port) as SSLSocket
        socket.enabledProtocols = arrayOf("TLSv1.3")
        socket.startHandshake()
        return SocketStream(socket)
    }

    fun listen(policy: PinPolicy, onAccept: (ByteStream) -> Unit): ServerHandle {
        val ctx = sslContext(policy)
        val server = ctx.serverSocketFactory.createServerSocket(0) as SSLServerSocket
        server.needClientAuth = true
        server.enabledProtocols = arrayOf("TLSv1.3")
        val thread = Thread {
            while (!server.isClosed) {
                val s = try { server.accept() as SSLSocket } catch (_: Exception) { break }
                Thread { runCatching { s.startHandshake(); onAccept(SocketStream(s)) } }.start()
            }
        }.apply { isDaemon = true; start() }
        return ServerHandle(server.localPort, server, thread)
    }

    class ServerHandle(val port: Int, private val socket: SSLServerSocket, private val t: Thread) {
        fun close() = runCatching { socket.close() }.let {}
    }

    // --- NSD advertise/discover ---

    fun advertise(port: Int, deviceId: String, name: String, deviceClass: String) {
        val info = NsdServiceInfo().apply {
            serviceName = name
            serviceType = Proto.SERVICE_TYPE
            setPort(port)
            setAttribute("id", deviceId)
            setAttribute("nm", name)
            setAttribute("cl", deviceClass)
            setAttribute("v", Proto.VERSION)
        }
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(s: NsdServiceInfo) {}
            override fun onRegistrationFailed(s: NsdServiceInfo, code: Int) {}
            override fun onServiceUnregistered(s: NsdServiceInfo) {}
            override fun onUnregistrationFailed(s: NsdServiceInfo, code: Int) {}
        })
    }

    fun discover(onFound: (DiscoveredPeer) -> Unit, onLost: (String) -> Unit) {
        nsd.discoverServices(Proto.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, object : NsdManager.DiscoveryListener {
            override fun onServiceFound(info: NsdServiceInfo) {
                nsd.resolveService(info, object : NsdManager.ResolveListener {
                    override fun onServiceResolved(r: NsdServiceInfo) {
                        val attrs = r.attributes
                        onFound(
                            DiscoveredPeer(
                                serviceName = r.serviceName,
                                host = r.host?.hostAddress ?: return,
                                port = r.port,
                                deviceId = attrs["id"]?.let { String(it) },
                                name = attrs["nm"]?.let { String(it) } ?: r.serviceName,
                                deviceClass = attrs["cl"]?.let { String(it) } ?: "unknown",
                            )
                        )
                    }
                    override fun onResolveFailed(info: NsdServiceInfo, code: Int) {}
                })
            }
            override fun onServiceLost(info: NsdServiceInfo) = onLost(info.serviceName)
            override fun onDiscoveryStarted(t: String) {}
            override fun onDiscoveryStopped(t: String) {}
            override fun onStartDiscoveryFailed(t: String, code: Int) {}
            override fun onStopDiscoveryFailed(t: String, code: Int) {}
        })
    }
}

data class DiscoveredPeer(
    val serviceName: String, val host: String, val port: Int,
    val deviceId: String?, val name: String, val deviceClass: String,
)

/** Wraps an SSLSocket as a core [ByteStream], exposing the pinned peer key hash. */
private class SocketStream(private val socket: SSLSocket) : ByteStream {
    override val input: InputStream = socket.inputStream
    override val output: OutputStream = socket.outputStream
    override val peerTlsKeyHash: ByteArray? = run {
        val leaf = socket.session.peerCertificates.firstOrNull() as? X509Certificate ?: return@run null
        (leaf.publicKey as? java.security.interfaces.ECPublicKey)?.let { TlsMaterial.publicKeyHashX963(it) }
    }
    override fun close() { runCatching { socket.close() } }
}

/** Presents this device's single self-signed cert for both client + server roles. */
private class SingleCertKeyManager(private val material: TlsMaterial) : X509ExtendedKeyManager() {
    private val alias = "conduit"
    override fun getClientAliases(k: String?, i: Array<out java.security.Principal>?) = arrayOf(alias)
    override fun chooseClientAlias(k: Array<out String>?, i: Array<out java.security.Principal>?, s: java.net.Socket?) = alias
    override fun getServerAliases(k: String?, i: Array<out java.security.Principal>?) = arrayOf(alias)
    override fun chooseServerAlias(k: String?, i: Array<out java.security.Principal>?, s: java.net.Socket?) = alias
    override fun getCertificateChain(a: String?) = arrayOf(material.certificate)
    override fun getPrivateKey(a: String?) = material.privateKey
}

/** Verifies the peer by pinned public-key hash only; chain evaluation is never
 *  consulted (trust comes from pairing, docs/protocol.md §Security). */
private class PinningTrustManager(private val policy: LanTransport.PinPolicy) : X509TrustManager {
    private fun check(chain: Array<out X509Certificate>) {
        val leaf = chain.firstOrNull() ?: throw java.security.cert.CertificateException("no peer cert")
        val ec = leaf.publicKey as? java.security.interfaces.ECPublicKey
            ?: throw java.security.cert.CertificateException("peer key not EC")
        val hex = TlsMaterial.publicKeyHashX963(ec).joinToString("") { "%02x".format(it) }
        if (!policy.allows(hex)) throw java.security.cert.CertificateException("peer key $hex not pinned")
    }
    override fun checkClientTrusted(chain: Array<out X509Certificate>, authType: String?) = check(chain)
    override fun checkServerTrusted(chain: Array<out X509Certificate>, authType: String?) = check(chain)
    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}
