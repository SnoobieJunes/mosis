package org.conduit.android.capability

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.*
import android.content.Context
import android.content.pm.PackageManager
import androidx.annotation.RequiresPermission
import java.util.concurrent.Executors

/**
 * The headline Phase 5 feature (spec §9 Phase 5 step 6): the phone registers as
 * a real Bluetooth HID peripheral — a combined keyboard + trackpad — usable by
 * ANY host (an iPad, a smart TV, a locked-down PC) with ZERO Conduit software on
 * the host. This is the purest realization of the 2011 peripherals pillar: not
 * "our protocol to our app", but a genuine BT keyboard/mouse the OS just accepts.
 *
 * Uses BluetoothHidDevice (API 28+). The report map below describes a boot
 * keyboard (report id 1) plus a relative-pointing mouse (report id 2); the same
 * trackpad/keyboard surface that drives a Conduit peer drives this instead when
 * the user flips the mode switch.
 */
class BluetoothHidMode(private val context: Context) {

    interface Listener {
        fun onRegistered() {}
        fun onConnected(device: BluetoothDevice) {}
        fun onDisconnected() {}
        fun onUnavailable(reason: String) {}
    }

    private val executor = Executors.newSingleThreadExecutor()
    private var service: BluetoothHidDevice? = null
    private var host: BluetoothDevice? = null
    private var listener: Listener = object : Listener {}
    private var adapter: BluetoothAdapter? = null
    /**
     * Bumped on every start/stop so a late ServiceListener callback from a
     * previous session cannot install its proxy over the current one — the
     * profile proxy arrives asynchronously, and stop() used to leave the old
     * listener live with nothing to invalidate it (2026-08-17).
     */
    private var generation = 0

    fun isSupported(): Boolean =
        context.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH)

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    fun start(listener: Listener) {
        this.listener = listener
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
        if (adapter == null || !adapter.isEnabled) {
            listener.onUnavailable("Bluetooth is off")
            return
        }
        this.adapter = adapter
        val mine = ++generation
        adapter.getProfileProxy(context, object : BluetoothProfile.ServiceListener {
            // The hasConnectPermission() guard below is the real check; the
            // annotation on the enclosing start() cannot reach inside this
            // anonymous object, which is the only reason lint needs telling.
            @SuppressLint("MissingPermission")
            override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                if (profile != BluetoothProfile.HID_DEVICE) return
                if (mine != generation) {
                    // A stale callback: this session was already stopped. Hand
                    // the proxy straight back instead of overwriting the live one.
                    closeProxy(proxy)
                    return
                }
                service = proxy as BluetoothHidDevice
                if (!hasConnectPermission()) {
                    listener.onUnavailable("Nearby devices (Bluetooth) permission is not granted")
                    return
                }
                registerApp()
            }
            override fun onServiceDisconnected(profile: Int) {
                if (mine == generation) service = null
            }
        }, BluetoothProfile.HID_DEVICE)
    }

    private fun hasConnectPermission(): Boolean =
        context.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED

    /** Give a profile proxy back to the system; not doing so leaks the binding. */
    private fun closeProxy(proxy: BluetoothProfile) {
        runCatching { adapter?.closeProfileProxy(BluetoothProfile.HID_DEVICE, proxy) }
    }

    // Reached only after an explicit hasConnectPermission() check in the
    // ServiceListener callback above; lint cannot follow that across the
    // asynchronous hop, so this one check is suppressed here.
    @SuppressLint("MissingPermission")
    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    private fun registerApp() {
        val svc = service ?: return
        val sdp = BluetoothHidDeviceAppSdpSettings(
            "Conduit", "Keyboard & Trackpad", "Conduit",
            BluetoothHidDevice.SUBCLASS1_COMBO, REPORT_MAP,
        )
        svc.registerApp(sdp, null, null, executor, object : BluetoothHidDevice.Callback() {
            override fun onAppStatusChanged(pluggedDevice: BluetoothDevice?, registered: Boolean) {
                if (registered) listener.onRegistered()
            }
            override fun onConnectionStateChanged(device: BluetoothDevice, state: Int) {
                when (state) {
                    BluetoothProfile.STATE_CONNECTED -> { host = device; listener.onConnected(device) }
                    BluetoothProfile.STATE_DISCONNECTED -> { host = null; listener.onDisconnected() }
                }
            }
        })
    }

    // --- sending input as HID reports ---

    /** Relative pointer move + button state (report id 2). buttons bit0=left,1=right,2=middle. */
    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    fun sendPointer(dx: Int, dy: Int, buttons: Int = 0, wheel: Int = 0) {
        val svc = service ?: return; val h = host ?: return
        val report = byteArrayOf(
            (buttons and 0x07).toByte(),
            dx.coerceIn(-127, 127).toByte(),
            dy.coerceIn(-127, 127).toByte(),
            wheel.coerceIn(-127, 127).toByte(),
        )
        svc.sendReport(h, REPORT_ID_MOUSE, report)
    }

    /** Press then release a key by USB HID usage id with modifier byte (report id 1). */
    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    fun sendKey(usage: Int, modifiers: Int = 0) {
        val svc = service ?: return; val h = host ?: return
        // Boot keyboard report: [modifiers, reserved, k1..k6].
        val down = byteArrayOf(modifiers.toByte(), 0, usage.toByte(), 0, 0, 0, 0, 0)
        val up = ByteArray(8)
        svc.sendReport(h, REPORT_ID_KEYBOARD, down)
        svc.sendReport(h, REPORT_ID_KEYBOARD, up)
    }

    @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT)
    fun stop() {
        generation++
        val svc = service
        if (svc != null) {
            svc.unregisterApp()
            // The proxy was never returned before 2026-08-17: every start/stop
            // cycle leaked a profile binding for the process's lifetime.
            closeProxy(svc)
        }
        service = null; host = null
    }

    val connectedHostName: String? @RequiresPermission(Manifest.permission.BLUETOOTH_CONNECT) get() = host?.name

    companion object {
        const val REPORT_ID_KEYBOARD = 1
        const val REPORT_ID_MOUSE = 2

        // HID report descriptor: boot keyboard (id 1) + relative mouse (id 2).
        private val REPORT_MAP = byteArrayOf(
            // Keyboard
            0x05, 0x01,             // Usage Page (Generic Desktop)
            0x09, 0x06,             // Usage (Keyboard)
            0xA1.toByte(), 0x01,    // Collection (Application)
            0x85.toByte(), 0x01,    //   Report ID (1)
            0x05, 0x07,             //   Usage Page (Key Codes)
            0x19, 0xE0.toByte(),    //   Usage Min (224)
            0x29, 0xE7.toByte(),    //   Usage Max (231)
            0x15, 0x00,             //   Logical Min (0)
            0x25, 0x01,             //   Logical Max (1)
            0x75, 0x01,             //   Report Size (1)
            0x95.toByte(), 0x08,    //   Report Count (8) -> modifier byte
            0x81.toByte(), 0x02,    //   Input (Data,Var,Abs)
            0x95.toByte(), 0x01,    //   Report Count (1)
            0x75, 0x08,             //   Report Size (8) -> reserved
            0x81.toByte(), 0x01,    //   Input (Const)
            0x95.toByte(), 0x06,    //   Report Count (6)
            0x75, 0x08,             //   Report Size (8)
            0x15, 0x00, 0x25, 0x65, //   Logical 0..101
            0x05, 0x07,             //   Usage Page (Key Codes)
            0x19, 0x00, 0x29, 0x65, //   Usage 0..101
            0x81.toByte(), 0x00,    //   Input (Data,Array) -> 6 keys
            0xC0.toByte(),          // End Collection
            // Mouse
            0x05, 0x01,             // Usage Page (Generic Desktop)
            0x09, 0x02,             // Usage (Mouse)
            0xA1.toByte(), 0x01,    // Collection (Application)
            0x85.toByte(), 0x02,    //   Report ID (2)
            0x09, 0x01,             //   Usage (Pointer)
            0xA1.toByte(), 0x00,    //   Collection (Physical)
            0x05, 0x09,             //     Usage Page (Buttons)
            0x19, 0x01, 0x29, 0x03, //     Usage 1..3
            0x15, 0x00, 0x25, 0x01, //     Logical 0..1
            0x95.toByte(), 0x03, 0x75, 0x01, //  3 bits
            0x81.toByte(), 0x02,    //     Input (Data,Var,Abs)
            0x95.toByte(), 0x01, 0x75, 0x05, //  5-bit pad
            0x81.toByte(), 0x01,    //     Input (Const)
            0x05, 0x01,             //     Usage Page (Generic Desktop)
            0x09, 0x30, 0x09, 0x31, 0x09, 0x38, // X, Y, Wheel
            0x15, 0x81.toByte(), 0x25, 0x7F, //  Logical -127..127
            0x75, 0x08, 0x95.toByte(), 0x03, //  3 bytes
            0x81.toByte(), 0x06,    //     Input (Data,Var,Rel)
            0xC0.toByte(),          //   End Collection
            0xC0.toByte(),          // End Collection
        )
    }
}
