package org.conduit.android.transport

import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.aware.*
import android.os.Build
import androidx.annotation.RequiresApi
import java.net.Inet6Address
import java.net.InetSocketAddress

/**
 * Wi-Fi Aware backend (spec §9 Phase 5 steps 3-4): the accelerator, never a
 * dependency — the LAN backend is always on. Same-platform (Android↔Android)
 * Aware works on hardware that reports `FEATURE_WIFI_AWARE`; iPhone↔Android
 * Aware is the gated probe that currently breaks at the encrypted pairing stage
 * on most devices (docs/interop-status.md), re-tested each OS cycle.
 *
 * This publishes/subscribes the same service name the other platforms use; the
 * data-path connection then carries the identical MOSIS session bytes.
 *
 * **Verification status: none.** Every line below is hardware-blocked — Aware
 * needs two devices reporting `FEATURE_WIFI_AWARE`, and no such device has run
 * this. What changed is that it is now *possible* for it to work: the subscribe
 * callback used to contain a cast that could never succeed (`this as?
 * SubscribeDiscoverySession` inside a `DiscoverySessionCallback`, which is a
 * different type — so it always produced null and no peer was ever reported),
 * and the data path was never written at all. Both are fixed here. It remains
 * unproven, and `AwareAvailability` is what the app checks before offering it.
 */
@RequiresApi(Build.VERSION_CODES.O)
class WifiAwareBackend(private val context: Context) {

    /** Why Aware isn't usable, in the user's terms — or null when it is. */
    fun unavailableReason(): String? {
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)) {
            return "This device's Wi-Fi chipset doesn't support Wi-Fi Aware."
        }
        val mgr = context.getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager
            ?: return "Wi-Fi Aware service unavailable."
        if (!mgr.isAvailable) return "Wi-Fi Aware is off — turn Wi-Fi on and try again."
        return null
    }

    fun isAvailable(): Boolean = unavailableReason() == null

    /** A live publish or subscribe session plus the attach that owns it. */
    class Handle(
        private val session: WifiAwareSession,
        private val discovery: DiscoverySession?,
    ) {
        fun close() {
            discovery?.close()
            session.close()
        }
    }

    /** Attaches to the Aware service, then publishes under the MOSIS name. */
    fun publish(
        serviceName: String,
        onReady: (Handle) -> Unit,
        onPeerMessage: (DiscoverySession, PeerHandle) -> Unit,
        onUnavailable: (String) -> Unit,
    ) {
        val mgr = context.getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager
        if (mgr == null || !mgr.isAvailable) return onUnavailable(unavailableReason() ?: "unavailable")
        mgr.attach(object : AttachCallback() {
            override fun onAttached(awareSession: WifiAwareSession) {
                val config = PublishConfig.Builder().setServiceName(serviceName).build()
                awareSession.publish(config, object : DiscoverySessionCallback() {
                    /// Captured here rather than reached for through `this`:
                    /// the callback object is a `DiscoverySessionCallback`, not
                    /// a `DiscoverySession`, and confusing the two is exactly
                    /// the bug the subscribe path shipped with.
                    private var publish: PublishDiscoverySession? = null

                    override fun onPublishStarted(session: PublishDiscoverySession) {
                        publish = session
                        onReady(Handle(awareSession, session))
                    }

                    // A subscriber must speak first so the publisher learns its
                    // PeerHandle; without a handle there is nobody to build a
                    // network specifier against.
                    override fun onMessageReceived(peerHandle: PeerHandle, message: ByteArray?) {
                        onPeerMessage(publish ?: return, peerHandle)
                    }
                }, null)
            }
            override fun onAttachFailed() = onUnavailable("attach failed")
        }, null)
    }

    /** Subscribes and reports discovered publishers (peers) to connect to. */
    fun subscribe(
        serviceName: String,
        onPeer: (SubscribeDiscoverySession, PeerHandle) -> Unit,
        onUnavailable: (String) -> Unit,
    ) {
        val mgr = context.getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager
        if (mgr == null || !mgr.isAvailable) return onUnavailable(unavailableReason() ?: "unavailable")
        mgr.attach(object : AttachCallback() {
            override fun onAttached(session: WifiAwareSession) {
                val config = SubscribeConfig.Builder().setServiceName(serviceName).build()
                session.subscribe(config, object : DiscoverySessionCallback() {
                    /// Captured from onSubscribeStarted. The previous code tried
                    /// `this as? SubscribeDiscoverySession` from inside the
                    /// callback object — a cast between two unrelated types,
                    /// which is always null, so `onPeer` was never called and
                    /// discovery silently found nothing forever.
                    private var subscribeSession: SubscribeDiscoverySession? = null

                    override fun onSubscribeStarted(subscribe: SubscribeDiscoverySession) {
                        subscribeSession = subscribe
                    }

                    override fun onServiceDiscovered(
                        peerHandle: PeerHandle,
                        serviceSpecificInfo: ByteArray?,
                        matchFilter: MutableList<ByteArray>?,
                    ) {
                        val subscribe = subscribeSession ?: return
                        // The publisher only learns our PeerHandle once we send
                        // it something, and it needs that handle to accept the
                        // data path. One byte is enough.
                        subscribe.sendMessage(peerHandle, MESSAGE_ID, HELLO_PING)
                        onPeer(subscribe, peerHandle)
                    }
                }, null)
            }
            override fun onAttachFailed() = onUnavailable("attach failed")
        }, null)
    }

    /**
     * Opens the Aware data path and reports the socket address to connect the
     * ordinary TLS session over.
     *
     * This is the part that was never written: discovery alone carries no data.
     * `ConnectivityManager.requestNetwork` with a [WifiAwareNetworkSpecifier]
     * negotiates an IPv6 link between the two peers, and `LinkProperties` then
     * names the interface the peer's link-local address is scoped to — a scope
     * that must survive into the connect call, or the address is unroutable.
     *
     * The initiator (subscriber) passes the publisher's port; the responder
     * passes 0 and learns it from the peer.
     */
    fun requestDataPath(
        discovery: DiscoverySession,
        peer: PeerHandle,
        passphrase: String,
        port: Int,
        onReady: (network: Network, address: InetSocketAddress) -> Unit,
        onFailed: (String) -> Unit,
    ): ConnectivityManager.NetworkCallback {
        val specifier = WifiAwareNetworkSpecifier.Builder(discovery, peer)
            .apply {
                setPskPassphrase(passphrase)
                if (port > 0) setPort(port)
            }
            .build()
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_WIFI_AWARE)
            .setNetworkSpecifier(specifier)
            .build()
        val connectivity = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        val callback = object : ConnectivityManager.NetworkCallback() {
            private var network: Network? = null

            override fun onAvailable(network: Network) {
                this.network = network
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                val info = caps.transportInfo as? WifiAwareNetworkInfo ?: return
                val address = info.peerIpv6Addr ?: return
                val peerPort = if (info.port > 0) info.port else port
                if (peerPort <= 0) return    // responder side; it dials us instead
                onReady(network, InetSocketAddress(scoped(address, network, connectivity), peerPort))
            }

            override fun onUnavailable() {
                onFailed("Wi-Fi Aware data path could not be established.")
            }
        }
        connectivity.requestNetwork(request, callback, DATA_PATH_TIMEOUT_MS)
        return callback
    }

    /**
     * Re-scopes a link-local IPv6 address to the Aware interface.
     *
     * A link-local address without its scope id is meaningless — `connect()`
     * fails with "network is unreachable" and the cause is invisible. The
     * interface name comes from the network's [LinkProperties].
     */
    private fun scoped(
        address: Inet6Address, network: Network, connectivity: ConnectivityManager,
    ): Inet6Address {
        val link: LinkProperties = connectivity.getLinkProperties(network) ?: return address
        val name = link.interfaceName ?: return address
        return runCatching {
            Inet6Address.getByAddress(null, address.address, java.net.NetworkInterface.getByName(name))
        }.getOrDefault(address)
    }

    companion object {
        private const val MESSAGE_ID = 1
        private val HELLO_PING = byteArrayOf(0x01)
        private const val DATA_PATH_TIMEOUT_MS = 15_000
    }
}
