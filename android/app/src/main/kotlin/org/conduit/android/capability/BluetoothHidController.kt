package org.conduit.android.capability

import android.annotation.SuppressLint
import android.Manifest
import android.bluetooth.BluetoothDevice
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * Makes [BluetoothHidMode] reachable from the UI (AND-4).
 *
 * The HID profile itself was written and complete-looking, and nothing ever
 * constructed it — so the phone-as-a-real-Bluetooth-keyboard feature existed
 * only in the source tree. This holds the one instance, owns the permission
 * check, and exposes a status line honest enough to explain every way it can
 * fail to connect.
 *
 * Off the MOSIS wire entirely: this is a genuine BT-HID peripheral, so it types
 * into an iPad or a TV with nothing installed. It is also the one capability
 * here that cannot be exercised without two physical devices.
 */
// Every profile call below goes through runWithPermission, which re-checks
// BLUETOOTH_CONNECT and catches the SecurityException — but lint cannot see into
// a lambda, so it reports each one. Suppressed here, deliberately narrowly (this
// check only), so that `gradlew lintDebug` can be a CI gate for the checks that
// do matter — NewApi above all, which is how the declared minSdk stayed wrong
// while an API-33 call sat on the first-launch path (2026-08-17).
@SuppressLint("MissingPermission")
class BluetoothHidController(private val context: Context) {
    private val mode = BluetoothHidMode(context)

    /** Human-readable status, or null before anything has been attempted. */
    val state = MutableStateFlow<String?>(null)
    private var host: BluetoothDevice? = null

    fun isSupported(): Boolean = mode.isSupported()

    private fun hasPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED

    fun start() {
        if (!isSupported()) {
            state.value = "This device has no Bluetooth radio."
            return
        }
        if (!hasPermission()) {
            // Saying which permission, rather than failing silently, is the
            // difference between a fixable problem and a broken feature.
            state.value = "Allow Nearby devices (Bluetooth) for MOSIS in Settings, then try again."
            return
        }
        state.value = "Registering as a Bluetooth keyboard…"
        // The permission is checked directly above, and a revocation between
        // that check and this call surfaces as a SecurityException — handled
        // here explicitly rather than through the runWithPermission helper,
        // whose lambda lint cannot see into.
        try {
            mode.start(object : BluetoothHidMode.Listener {
                override fun onRegistered() {
                    state.value = "Ready — now pair this phone from the other device's Bluetooth settings."
                }
                override fun onConnected(device: BluetoothDevice) {
                    host = device
                    state.value = "Connected as a keyboard and trackpad."
                }
                override fun onDisconnected() {
                    host = null
                    state.value = "Disconnected. Reconnect from the host's Bluetooth settings."
                }
                override fun onUnavailable(reason: String) {
                    state.value = "Bluetooth HID unavailable: $reason"
                }
            })
        } catch (e: SecurityException) {
            state.value = "Bluetooth permission was revoked."
        }
    }

    fun stop() {
        runWithPermission { mode.stop() }
        host = null
        state.value = null
    }

    fun move(dx: Int, dy: Int) = runWithPermission { mode.sendPointer(dx, dy) }
    fun click() = runWithPermission {
        mode.sendPointer(0, 0, buttons = 1)
        mode.sendPointer(0, 0, buttons = 0)
    }
    fun rightClick() = runWithPermission {
        mode.sendPointer(0, 0, buttons = 2)
        mode.sendPointer(0, 0, buttons = 0)
    }
    fun scroll(wheel: Int) = runWithPermission { mode.sendPointer(0, 0, wheel = wheel) }

    /** USB HID usage id + modifier byte; see [BluetoothHidMode.sendKey]. */
    fun key(usage: Int, modifiers: Int = 0) = runWithPermission { mode.sendKey(usage, modifiers) }

    /**
     * The profile calls are annotated `@RequiresPermission(BLUETOOTH_CONNECT)`;
     * the check is real rather than a lint suppression, so a revoked permission
     * mid-session degrades to a status message instead of a SecurityException.
     */
    // NOT inline: the @Suppress does not travel with an inlined body, so every
    // call site was reported by `gradlew lintDebug` as MissingPermission even
    // though the check below is real (2026-08-17).
    @Suppress("MissingPermission")
    private fun runWithPermission(body: () -> Unit) {
        if (!hasPermission()) {
            state.value = "Bluetooth permission was revoked."
            return
        }
        runCatching { body() }.onFailure { state.value = "Bluetooth error: ${it.message}" }
    }
}
