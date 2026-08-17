package org.conduit.android.ui

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.conduit.android.ConduitRuntime
import org.conduit.android.ConduitService
import org.conduit.android.capability.ScreenShareStarter
import org.conduit.core.session.PairPrompt
import java.io.File
import kotlin.coroutines.resume
import kotlin.coroutines.suspendCoroutine

/**
 * The Android client entry point (spec §9 Phase 5 step 7: adaptive so it behaves
 * in Android 16 desktop windows — hence resizeableActivity + Compose reflowing).
 * Compose UI over the shared node; peer bubbles and the Connect/Share verb pair
 * mirror the Apple apps.
 */
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            val colors = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()
            MaterialTheme(colorScheme = colors) {
                // First launch mints Ed25519 + TLS keys — too slow for the main
                // thread, so bootstrap off it and show a placeholder meanwhile.
                var runtime by remember { mutableStateOf(ConduitRuntime.instance) }
                LaunchedEffect(Unit) {
                    if (runtime == null) {
                        runtime = withContext(Dispatchers.Default) { ConduitRuntime.ensure(applicationContext) }
                    }
                    ConduitService.start(this@MainActivity)
                }
                runtime?.let { ConduitApp(it) } ?: StartingScreen()
            }
        }
    }
}

@Composable
private fun StartingScreen() {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            CircularProgressIndicator()
            Spacer(Modifier.height(12.dp))
            Text("Starting MOSIS…", style = MaterialTheme.typography.bodyMedium)
        }
    }
}

/** State-based navigation: the device list, the remote-control surface, or a
 *  peer's screen. */
@Composable
fun ConduitApp(runtime: ConduitRuntime) {
    val node = runtime.node
    val connected by node.connected.collectAsStateWithLifecycle()
    val viewing by node.screens.viewing.collectAsStateWithLifecycle()
    var controllingPeerId by remember { mutableStateOf<String?>(null) }

    // Watching a screen wins the foreground; it is the more demanding surface
    // and it ends on its own when the source stops.
    val ctrl = controllingPeerId?.takeIf { it in connected }
    when {
        viewing != null -> {
            BackHandler { node.screens.stopViewing() }
            ScreenViewerRoute(runtime, onBack = { node.screens.stopViewing() })
        }
        ctrl != null -> {
            BackHandler { controllingPeerId = null }
            RemoteControlRoute(runtime, peerId = ctrl, onBack = { controllingPeerId = null })
        }
        else -> DevicesScreen(runtime, onControl = { controllingPeerId = it })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RemoteControlRoute(runtime: ConduitRuntime, peerId: String, onBack: () -> Unit) {
    val node = runtime.node
    val name = node.peerFor(peerId)?.name ?: "device"
    // Ask for control up front: the far end gates injection behind a consent
    // prompt, and sending events before it is granted drops them silently.
    LaunchedEffect(peerId) { node.requestInputControl(peerId) }
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Controlling $name") },
                navigationIcon = { TextButton(onClick = onBack) { Text("Back") } },
            )
        },
    ) { pad ->
        Box(Modifier.padding(pad)) {
            RemoteControlScreen(
                connectedHost = name,
                onMove = { dx, dy -> node.sendInputMove(peerId, dx, dy) },
                onClick = { node.sendInputClick(peerId) },
                onRightClick = { node.sendInputClick(peerId, "right") },
                onScroll = { dx, dy -> node.sendInputScroll(peerId, dx, dy) },
                onText = { text -> node.sendInputKey(peerId, text = text) },
                onSpecialKey = { key, mods -> node.sendInputKey(peerId, key = key, modifiers = mods) },
                onMedia = { action -> node.sendMediaControl(peerId, action) },
                hidMode = runtime.bluetoothHid,
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevicesScreen(runtime: ConduitRuntime, onControl: (String) -> Unit = {}) {
    val node = runtime.node
    val discovered by node.discovered.collectAsStateWithLifecycle()
    val pinned by node.pinned.collectAsStateWithLifecycle()
    val connected by node.connected.collectAsStateWithLifecycle()
    val toast by node.toast.collectAsStateWithLifecycle()
    val incomingClipboard by runtime.incomingClipboard.collectAsStateWithLifecycle()
    val incomingNotification by runtime.incomingNotification.collectAsStateWithLifecycle()
    val screenRequestFrom by node.screens.screenRequestFrom.collectAsStateWithLifecycle()
    val sourcing by node.screens.sourcing.collectAsStateWithLifecycle()
    var acceptPairing by remember { mutableStateOf(false) }
    var prompt by remember { mutableStateOf<Pair<PairPrompt, (Boolean) -> Unit>?>(null) }
    /** Device id (or nearby host) with an operation in flight — row spinner. */
    var busyWith by remember { mutableStateOf<String?>(null) }
    /** Peer a file is being picked for (AND-3: file SEND had no UI at all). */
    var sendFileTo by remember { mutableStateOf<String?>(null) }
    /** Manual host:port pairing, for peers that never advertise (2026-08-17). */
    var showManualConnect by remember { mutableStateOf(false) }
    /** deviceId to name of a peer being un-paired, pending confirmation. */
    var forgetPeer by remember { mutableStateOf<Pair<String, String>?>(null) }
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    val activity = context as? Activity

    // The system file picker. SAF hands back a content:// URI, which the file
    // sender needs as a real File, so it is copied into the cache first.
    val filePicker = rememberLauncherForActivityResult(
        ActivityResultContracts.GetContent()
    ) { uri ->
        val peerId = sendFileTo
        sendFileTo = null
        if (uri == null || peerId == null) return@rememberLauncherForActivityResult
        scope.launch(Dispatchers.IO) {
            val copied = runCatching {
                val name = uri.lastPathSegment?.substringAfterLast('/') ?: "shared"
                val out = File(context.cacheDir, name)
                context.contentResolver.openInputStream(uri)!!.use { input ->
                    out.outputStream().use { input.copyTo(it) }
                }
                out
            }.getOrNull()
            if (copied == null) node.toast.value = "Couldn't read that file"
            else node.sendFile(peerId, copied)
        }
    }

    // MediaProjection consent (AND-2). Must be launched from an Activity, and
    // the peer that asked has to survive the round trip.
    var projectionForPeer by remember { mutableStateOf<String?>(null) }
    val projectionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val peerId = projectionForPeer
        projectionForPeer = null
        if (peerId == null) return@rememberLauncherForActivityResult
        val failure = ScreenShareStarter.start(context, peerId, result.resultCode, result.data)
        if (failure != null) {
            node.screens.declineRequest(peerId, "source declined")
            node.toast.value = failure
        }
    }

    LaunchedEffect(Unit) {
        node.confirmPairing = { p -> suspendCoroutine { cont -> prompt = p to { ok -> prompt = null; cont.resume(ok) } } }
    }
    LaunchedEffect(acceptPairing) { node.pairingEnabled = acceptPairing }
    // Feedback is transient: clear it so a stale "Pairing failed" can't sit
    // on screen forever.
    LaunchedEffect(toast) {
        if (toast != null) {
            delay(3500)
            node.toast.value = null
        }
    }
    // NOTIFICATION display: `notify-show` was advertised unconditionally while
    // `incomingNotification` had no consumer at all, so a mirrored notification
    // arrived and vanished (2026-08-17). Shown in the snackbar, like clipboard.
    LaunchedEffect(incomingNotification) {
        incomingNotification?.let { (app, title, body) ->
            node.toast.value = "$app: $title — $body"
            runtime.incomingNotification.value = null
        }
    }
    // Clipboard RECEIVE had no UI either: text arrived and went nowhere.
    LaunchedEffect(incomingClipboard) {
        incomingClipboard?.let {
            clipboard.setText(AnnotatedString(it))
            node.toast.value = "Clipboard received"
            runtime.incomingClipboard.value = null
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("MOSIS") },
                actions = {
                    Text("Accept pairing", style = MaterialTheme.typography.labelMedium)
                    Switch(checked = acceptPairing, onCheckedChange = { acceptPairing = it })
                },
            )
        },
        snackbarHost = {
            toast?.let {
                Snackbar(Modifier.padding(12.dp)) { Text(it) }
            }
        },
    ) { pad ->
        LazyColumn(Modifier.padding(pad).fillMaxSize(), contentPadding = PaddingValues(16.dp)) {
            sourcing?.let { live ->
                item {
                    // The receiver-side invariant, applied to screens: sharing is
                    // always visibly indicated and instantly revocable.
                    ElevatedCard(Modifier.fillMaxWidth().padding(bottom = 12.dp)) {
                        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                "Sharing your screen with ${node.peerFor(live.peerId)?.name ?: "a device"}",
                                Modifier.weight(1f),
                                style = MaterialTheme.typography.bodyMedium,
                            )
                            Button(onClick = { ScreenShareStarter.stop(context) }) { Text("Stop") }
                        }
                    }
                }
            }
            item { ThisDeviceCard(node) }
            item { PermissionsCard(node) }
            item { SectionHeader("My devices") }
            if (pinned.isEmpty()) item { Hint("No paired devices yet. Turn on Accept pairing on one device, then tap the other under Nearby.") }
            items(pinned) { peer ->
                PairedRow(
                    name = peer.name,
                    deviceClass = peer.deviceClass,
                    isConnected = peer.deviceId in connected,
                    isBusy = busyWith == peer.deviceId,
                    onConnect = {
                        // Match by device id — NSD service names can carry
                        // dedup suffixes, so a name lookup misses silently.
                        val found = node.discoveredForDevice(peer.deviceId) ?: node.discoveredFor(peer.name)
                        if (found == null) {
                            node.toast.value = "${peer.name} isn't visible on this network"
                        } else {
                            busyWith = peer.deviceId
                            scope.launch {
                                try { node.connect(peer, found.host, found.port) } finally { busyWith = null }
                            }
                        }
                    },
                    onControl = { onControl(peer.deviceId) },
                    onWatchScreen = { node.screens.requestFrom(peer.deviceId) },
                    onSendFile = { sendFileTo = peer.deviceId; filePicker.launch("*/*") },
                    onSendClipboard = {
                        val text = clipboard.getText()?.text
                        if (text.isNullOrEmpty()) {
                            node.toast.value = "Clipboard has no text"
                        } else {
                            node.sendClipboard(peer.deviceId, text)
                            node.toast.value = "Clipboard sent to ${peer.name}"
                        }
                    },
                    // node.unpair() existed and had no caller, so a half-broken
                    // pairing could only be cleared by wiping app data
                    // (2026-08-17).
                    onForget = { forgetPeer = peer.deviceId to peer.name },
                )
            }
            item { Spacer(Modifier.height(16.dp)); SectionHeader("Nearby") }
            val nearby = discovered.filter { d -> pinned.none { it.deviceId == d.deviceId } }
            if (nearby.isEmpty()) item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(Modifier.size(16.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.width(8.dp))
                    Hint("Searching on the local network…")
                }
            }
            items(nearby) { d ->
                NearbyRow(
                    name = d.name,
                    deviceClass = d.deviceClass,
                    isBusy = busyWith == d.serviceName,
                    onPair = {
                        busyWith = d.serviceName
                        scope.launch {
                            try { node.pair(d.host, d.port) } finally { busyWith = null }
                        }
                    },
                )
            }
            // Not everything advertises itself. `conduitd` — the Go daemon, and
            // the only pairing partner available to a contributor without Apple
            // hardware — does not advertise over mDNS at all, so it can never
            // appear above. Before this existed (2026-08-17) there was no way to
            // reach it, which made the project's most-wanted contribution
            // impossible without owning a Mac.
            item {
                Spacer(Modifier.height(8.dp))
                OutlinedButton(onClick = { showManualConnect = true }, modifier = Modifier.fillMaxWidth()) {
                    Text("Pair by address…")
                }
                Hint("For a device that doesn't advertise itself — the conduitd daemon, or an emulator via adb reverse.")
            }
        }
    }

    if (showManualConnect) {
        var host by remember { mutableStateOf("") }
        var port by remember { mutableStateOf("") }
        AlertDialog(
            onDismissRequest = { showManualConnect = false },
            title = { Text("Pair by address") },
            text = {
                Column {
                    Text("The other device shows its address and port. Turn on Accept pairing there first.")
                    Spacer(Modifier.height(12.dp))
                    OutlinedTextField(
                        value = host,
                        onValueChange = { host = it.trim() },
                        label = { Text("Host or IP") },
                        singleLine = true,
                    )
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(
                        value = port,
                        onValueChange = { port = it.filter(Char::isDigit) },
                        label = { Text("Port") },
                        singleLine = true,
                    )
                }
            },
            confirmButton = {
                TextButton(
                    enabled = host.isNotEmpty() && port.toIntOrNull() != null,
                    onClick = {
                        val h = host
                        val p = port.toInt()
                        showManualConnect = false
                        busyWith = "$h:$p"
                        scope.launch { try { node.pair(h, p) } finally { busyWith = null } }
                    },
                ) { Text("Pair") }
            },
            dismissButton = { TextButton(onClick = { showManualConnect = false }) { Text("Cancel") } },
        )
    }

    forgetPeer?.let { (deviceId, name) ->
        AlertDialog(
            onDismissRequest = { forgetPeer = null },
            title = { Text("Forget $name?") },
            text = { Text("This device stops trusting $name and any live session ends. You can pair again with a fresh code. The other device keeps its own record until you unpair there too.") },
            confirmButton = {
                TextButton(onClick = {
                    node.unpair(deviceId)
                    node.toast.value = "Forgot $name"
                    forgetPeer = null
                }) { Text("Forget") }
            },
            dismissButton = { TextButton(onClick = { forgetPeer = null }) { Text("Cancel") } },
        )
    }

    prompt?.let { (p, resolve) ->
        AlertDialog(
            onDismissRequest = { resolve(false) },
            title = { Text("Pair with ${p.remoteName}?") },
            text = {
                Column {
                    Text("Confirm BOTH devices show exactly this:")
                    Spacer(Modifier.height(12.dp))
                    Text(p.code, style = MaterialTheme.typography.displaySmall)
                    Text("${p.wordA} · ${p.wordB}", style = MaterialTheme.typography.titleMedium)
                }
            },
            confirmButton = { TextButton(onClick = { resolve(true) }) { Text("They match") } },
            dismissButton = { TextButton(onClick = { resolve(false) }) { Text("Cancel") } },
        )
    }

    // A peer wants to see this screen. Consent twice on purpose: once for the
    // peer (this dialog) and once for the OS (MediaProjection), because the
    // second one cannot say *who* is asking.
    screenRequestFrom?.let { peerId ->
        val who = node.peerFor(peerId)?.name ?: "A device"
        AlertDialog(
            onDismissRequest = { node.screens.declineRequest(peerId) },
            title = { Text("Share your screen?") },
            text = { Text("$who wants to see this device's screen. Android will ask you to confirm screen capture as well.") },
            confirmButton = {
                TextButton(onClick = {
                    projectionForPeer = peerId
                    node.screens.screenRequestFrom.value = null
                    projectionLauncher.launch(ScreenShareStarter.consentIntent(context))
                }) { Text("Share") }
            },
            dismissButton = {
                TextButton(onClick = { node.screens.declineRequest(peerId) }) { Text("Not now") }
            },
        )
    }
}

/**
 * What this device is on the network.
 *
 * Added 2026-08-17. `AndroidNode.listenPort()` existed with no callers and the
 * app never showed its own address, so pairing was only possible with a peer
 * that advertises over mDNS — which `conduitd` does not do at all. Also the
 * first thing to quote in a bug report.
 */
@Composable
private fun ThisDeviceCard(node: org.conduit.android.AndroidNode) {
    val address = remember { node.localAddress() }
    // The port is only known after start(); poll briefly rather than block.
    var port by remember { mutableStateOf(node.listenPort()) }
    LaunchedEffect(Unit) {
        while (port == 0) { delay(250); port = node.listenPort() }
    }
    ElevatedCard(Modifier.fillMaxWidth().padding(bottom = 12.dp)) {
        Column(Modifier.padding(16.dp)) {
            Text("This device", style = MaterialTheme.typography.titleSmall)
            Spacer(Modifier.height(4.dp))
            Text(
                buildString {
                    append(android.os.Build.MODEL ?: "Android")
                    append(" · ")
                    append(address ?: "no LAN address")
                    append(if (port != 0) ":$port" else ":…")
                    append(" · id ")
                    append(node.deviceIdPrefix())
                },
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(4.dp))
            Hint("Another device can dial this address — e.g. conduitd pair --host ${address ?: "<ip>"} --port ${if (port != 0) "$port" else "<port>"}")
        }
    }
}

/**
 * Live state of the consent-gated capabilities, each with a way to grant it.
 *
 * Added 2026-08-17, because none of this existed: the app declared
 * BLUETOOTH_CONNECT and POST_NOTIFICATIONS and never requested either (so
 * BT-HID mode, described in the code as the headline Phase 5 feature, could
 * never be enabled from inside the app), and there was no `Settings.ACTION_*`
 * intent anywhere in the module — the AccessibilityService and the notification
 * listener were enable-by-folklore. A capability MOSIS advertises to peers
 * should be visible and reachable here.
 */
@Composable
private fun PermissionsCard(node: org.conduit.android.AndroidNode) {
    val context = LocalContext.current
    var tick by remember { mutableStateOf(0) }
    // Consent granted in system Settings comes back with no callback, so
    // re-read while this screen is showing.
    LaunchedEffect(Unit) { while (true) { delay(1500); tick++ } }

    val notificationsGranted = remember(tick) {
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }
    val bluetoothGranted = remember(tick) {
        ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED
    }
    val accessibilityOn = remember(tick) { node.canReceiveInput }
    val notificationSourceOn = remember(tick) { node.canSourceNotifications }

    val askNotifications = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { tick++ }
    val askBluetooth = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        tick++
        if (!granted) node.toast.value = "Without Nearby devices permission, MOSIS can't act as a Bluetooth keyboard."
    }

    ElevatedCard(Modifier.fillMaxWidth().padding(bottom = 12.dp)) {
        Column(Modifier.padding(16.dp)) {
            Text("Permissions & capabilities", style = MaterialTheme.typography.titleSmall)
            Hint("Each one MOSIS advertises to your other devices only while it is on.")
            Spacer(Modifier.height(8.dp))
            CapabilityRow(
                label = "Let a paired device control this one",
                detail = if (accessibilityOn) "On — MOSIS advertises input-inject" else "Off — Accessibility service is disabled",
                on = accessibilityOn,
                actionLabel = "Settings",
                onAction = { context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)) },
            )
            CapabilityRow(
                label = "Send this phone's notifications",
                detail = if (notificationSourceOn) "On" else "Off — notification access is disabled",
                on = notificationSourceOn,
                actionLabel = "Settings",
                onAction = { context.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) },
            )
            CapabilityRow(
                label = "Show MOSIS's own notifications",
                detail = if (notificationsGranted) "Allowed" else "Not allowed — the background service has no visible indicator",
                on = notificationsGranted,
                actionLabel = "Allow",
                onAction = { askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS) },
            )
            CapabilityRow(
                label = "Act as a Bluetooth keyboard",
                detail = if (bluetoothGranted) "Allowed" else "Not allowed — BT-HID mode can't start",
                on = bluetoothGranted,
                actionLabel = "Allow",
                onAction = { askBluetooth.launch(Manifest.permission.BLUETOOTH_CONNECT) },
            )
        }
    }
}

@Composable
private fun CapabilityRow(
    label: String,
    detail: String,
    on: Boolean,
    actionLabel: String,
    onAction: () -> Unit,
) {
    Row(Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(label, style = MaterialTheme.typography.bodyMedium)
            Text(
                detail,
                style = MaterialTheme.typography.bodySmall,
                color = if (on) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (!on) TextButton(onClick = onAction) { Text(actionLabel) }
    }
}

@Composable private fun SectionHeader(text: String) =
    Text(text, style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(vertical = 8.dp))

@Composable private fun Hint(text: String) =
    Text(text, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)

@Composable
private fun PairedRow(
    name: String,
    deviceClass: String,
    isConnected: Boolean,
    isBusy: Boolean,
    onConnect: () -> Unit,
    onControl: () -> Unit,
    onWatchScreen: () -> Unit,
    onSendFile: () -> Unit,
    onSendClipboard: () -> Unit,
    onForget: () -> Unit,
) {
    ElevatedCard(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text(name, style = MaterialTheme.typography.titleMedium)
                    Text(
                        when {
                            isConnected -> "Connected · $deviceClass"
                            isBusy -> "Connecting… · $deviceClass"
                            else -> deviceClass
                        },
                        style = MaterialTheme.typography.bodySmall,
                        color = if (isConnected) MaterialTheme.colorScheme.primary
                        else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                when {
                    isBusy -> CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
                    isConnected -> Button(onClick = onWatchScreen) { Text("Watch screen") }
                    else -> Button(onClick = onConnect) { Text("Connect") }
                }
            }
            if (isConnected) {
                // The spec §8 verb pair, finally both present on Android: pull
                // (watch / control) above, push (file / clipboard) here. Every
                // one of these called an AndroidNode method that already
                // existed and that no UI reached.
                Spacer(Modifier.height(8.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilledTonalButton(onClick = onControl) { Text("Control") }
                    FilledTonalButton(onClick = onSendFile) { Text("Send file") }
                    FilledTonalButton(onClick = onSendClipboard) { Text("Clipboard") }
                }
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                TextButton(onClick = onForget) { Text("Forget") }
            }
        }
    }
}

@Composable
private fun NearbyRow(name: String, deviceClass: String, isBusy: Boolean, onPair: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(name)
            Text(
                if (isBusy) "Pairing…" else "Not paired · $deviceClass",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (isBusy) {
            CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
        } else {
            FilledTonalButton(onClick = onPair) { Text("Pair") }
        }
    }
}
