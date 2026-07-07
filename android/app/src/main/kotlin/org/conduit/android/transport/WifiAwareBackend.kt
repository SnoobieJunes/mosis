package org.conduit.android.transport

import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.aware.*
import android.os.Build
import androidx.annotation.RequiresApi

/**
 * Wi-Fi Aware backend (spec §9 Phase 5 steps 3-4): the accelerator, never a
 * dependency — the LAN backend is always on. Same-platform (Android↔Android)
 * Aware works today on hardware that reports FEATURE_WIFI_AWARE; iPhone↔Android
 * Aware is the gated probe that currently breaks at the encrypted pairing stage
 * on most devices (docs/interop-status.md), re-tested each OS cycle.
 *
 * This publishes/subscribes the same service name the other platforms use; the
 * data-path connection then carries the identical Conduit session bytes. OEM
 * behavior varies, so everything is availability-checked and falls back to LAN.
 */
@RequiresApi(Build.VERSION_CODES.O)
class WifiAwareBackend(private val context: Context) {

    fun isAvailable(): Boolean {
        if (!context.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_AWARE)) return false
        val mgr = context.getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager
        return mgr?.isAvailable == true
    }

    /** Attaches to the Aware service, then publishes under the Conduit name. */
    fun publish(serviceName: String, onSession: (PublishDiscoverySession) -> Unit, onUnavailable: (String) -> Unit) {
        val mgr = context.getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager
        if (mgr == null || !mgr.isAvailable) return onUnavailable("Wi-Fi Aware unavailable")
        mgr.attach(object : AttachCallback() {
            override fun onAttached(session: WifiAwareSession) {
                val config = PublishConfig.Builder().setServiceName(serviceName).build()
                session.publish(config, object : DiscoverySessionCallback() {
                    override fun onPublishStarted(s: PublishDiscoverySession) = onSession(s)
                }, null)
            }
            override fun onAttachFailed() = onUnavailable("attach failed")
        }, null)
    }

    /** Subscribes and reports discovered publishers (peers) to connect to. */
    fun subscribe(serviceName: String, onPeer: (SubscribeDiscoverySession, PeerHandle) -> Unit, onUnavailable: (String) -> Unit) {
        val mgr = context.getSystemService(Context.WIFI_AWARE_SERVICE) as? WifiAwareManager
        if (mgr == null || !mgr.isAvailable) return onUnavailable("Wi-Fi Aware unavailable")
        mgr.attach(object : AttachCallback() {
            override fun onAttached(session: WifiAwareSession) {
                val config = SubscribeConfig.Builder().setServiceName(serviceName).build()
                session.subscribe(config, object : DiscoverySessionCallback() {
                    override fun onServiceDiscovered(
                        peerHandle: PeerHandle, serviceSpecificInfo: ByteArray?, matchFilter: MutableList<ByteArray>?,
                    ) {
                        // A publisher matched; the data-path connection is set up
                        // via ConnectivityManager with a WifiAwareNetworkSpecifier,
                        // then the Conduit session runs over that socket unchanged.
                        (this as? SubscribeDiscoverySession)?.let { onPeer(it, peerHandle) }
                    }
                }, null)
            }
            override fun onAttachFailed() = onUnavailable("attach failed")
        }, null)
    }
}
