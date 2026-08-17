package org.conduit.android

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import org.conduit.android.capability.BluetoothHidController
import org.conduit.android.transport.TlsMaterial
import org.conduit.core.identity.Identity
import org.conduit.core.wire.Json
import org.conduit.core.wire.asObj
import org.conduit.core.wire.str
import java.io.File

/**
 * Process-wide singleton the Android services (Accessibility, Notification
 * listener, the foreground service) reach to talk to the running node without a
 * bound-service dance. Holds the [AndroidNode] plus the small pieces of UI
 * state the capability services feed.
 */
class ConduitRuntime private constructor(
    val node: AndroidNode,
    /** Phone-as-a-real-Bluetooth-keyboard. Off the MOSIS wire entirely; held
     *  here so the control surface can reach it (AND-4). */
    val bluetoothHid: BluetoothHidController,
) {

    val incomingClipboard = MutableStateFlow<String?>(null)
    val incomingNotification = MutableStateFlow<Triple<String, String, String>?>(null)

    /** Per-app filter for notification sourcing; empty = mirror all. */
    val mirroredPackages = MutableStateFlow<Set<String>>(emptySet())

    fun shouldMirror(pkg: String): Boolean =
        mirroredPackages.value.isEmpty() || pkg in mirroredPackages.value

    fun mirrorNotification(app: String, title: String, body: String, id: String) =
        node.mirrorNotification(app, title, body, id)

    fun onInputReceiverAvailable(available: Boolean) { node.canReceiveInput = available }
    fun onNotificationSourceAvailable(available: Boolean) { node.canSourceNotifications = available }
    fun onClipboardReceived(text: String) { incomingClipboard.value = text }
    /// A controller asked for something Android has no API for. Surfaced rather
    /// than dropped: a key that does nothing and says nothing is the failure
    /// mode this project keeps having to fix.
    fun onInputUnsupported(reason: String) { node.toast.value = reason }
    fun onNotificationReceived(payload: Json) {
        val o = payload.asObj()
        incomingNotification.value = Triple(o.getValue("app_name").str(), o.getValue("title").str(), o.getValue("body").str())
    }

    companion object {
        @Volatile var instance: ConduitRuntime? = null
            private set

        /**
         * Loads or mints the identity + TLS material and builds the node.
         *
         * Synchronized since 2026-08-17. It is called from two threads —
         * MainActivity's `LaunchedEffect` via `Dispatchers.Default`, and
         * `ConduitService.onCreate` on the main thread — and `ConduitService` is
         * START_STICKY, so the system can restart it while an Activity is
         * launching after process death. Unsynchronized, both callers could pass
         * the null check and mint two identities, racing the writes to
         * `ed25519.seed` / `tls.p8`: a half-written seed or a key pair that does
         * not match the advertised public key, on the exact first-launch path
         * the Conscrypt bug already broke once.
         */
        @Synchronized
        fun ensure(context: Context): ConduitRuntime {
            instance?.let { return it }
            val appCtx = context.applicationContext
            val dir = File(appCtx.filesDir, "conduit").apply { mkdirs() }
            val (identity, material) = loadOrCreate(appCtx, dir)
            val name = android.os.Build.MODEL ?: "Android"
            val receive = File(appCtx.getExternalFilesDir(null), "Conduit").apply { mkdirs() }
            val node = AndroidNode(appCtx, identity, material, name, receive)
            return ConduitRuntime(node, BluetoothHidController(appCtx)).also { instance = it }
        }

        private fun loadOrCreate(context: Context, dir: File): Pair<Identity, TlsMaterial> {
            // BOTH halves of the Ed25519 identity are stored. Storing only the
            // seed forced a re-derivation on every launch through
            // `Identity.fromSeed`, whose public-key derivation assumes an
            // OpenJDK generator behaviour that Android's Conscrypt does not
            // share — so the device advertised a public key its signatures did
            // not match, and pairing could not complete. (A KeyStore-backed
            // store is a hardening follow-up; the file is inside the app's
            // private `filesDir`.)
            val seedFile = File(dir, "ed25519.seed")
            val pubFile = File(dir, "ed25519.pub")
            val identity = if (seedFile.exists() && pubFile.exists()) {
                Identity(seedFile.readBytes(), pubFile.readBytes()).also { it.assertConsistent() }
            } else {
                Identity.generate().also {
                    // Write via a temp file + rename so a kill mid-write cannot
                    // leave a truncated seed that then fails assertConsistent()
                    // on every later launch (2026-08-17).
                    writeAtomically(seedFile, it.privateSeed)
                    writeAtomically(pubFile, it.publicKeyRaw)
                }
            }
            // TLS material is persisted too: peers pin the hash of this key at
            // pairing, so minting a new one each launch orphaned every pairing.
            val material = TlsMaterial.loadOrCreate(
                keyFile = File(dir, "tls.p8"),
                certFile = File(dir, "tls.cer"),
                commonName = "conduit-${identity.deviceId.take(16)}",
            )
            return identity to material
        }

        private fun writeAtomically(target: File, bytes: ByteArray) {
            val tmp = File(target.parentFile, target.name + ".tmp")
            tmp.writeBytes(bytes)
            if (!tmp.renameTo(target)) {
                // Same directory, so a rename should not fail; fall back rather
                // than leaving the identity unwritten.
                target.writeBytes(bytes)
                tmp.delete()
            }
        }
    }
}
