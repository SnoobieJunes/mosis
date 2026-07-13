package org.conduit.android.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.conduit.android.ConduitRuntime
import org.conduit.android.ConduitService
import org.conduit.core.session.PairPrompt
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
            Text("Starting Conduit…", style = MaterialTheme.typography.bodyMedium)
        }
    }
}

/** State-based navigation: the device list, or the remote-control surface for
 *  one connected peer. */
@Composable
fun ConduitApp(runtime: ConduitRuntime) {
    val node = runtime.node
    val connected by node.connected.collectAsStateWithLifecycle()
    var controllingPeerId by remember { mutableStateOf<String?>(null) }

    // Leave the trackpad if the session drops out from under it.
    val ctrl = controllingPeerId?.takeIf { it in connected }
    if (ctrl != null) {
        BackHandler { controllingPeerId = null }
        RemoteControlRoute(runtime, peerId = ctrl, onBack = { controllingPeerId = null })
    } else {
        DevicesScreen(runtime, onControl = { controllingPeerId = it })
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RemoteControlRoute(runtime: ConduitRuntime, peerId: String, onBack: () -> Unit) {
    val node = runtime.node
    val name = node.peerFor(peerId)?.name ?: "device"
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
                onModeChange = { /* Bluetooth HID mode is device-gated (ADR); the
                                    Conduit-peer path is what's wired here. */ },
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
    var acceptPairing by remember { mutableStateOf(false) }
    var prompt by remember { mutableStateOf<Pair<PairPrompt, (Boolean) -> Unit>?>(null) }
    /** Device id (or nearby host) with an operation in flight — row spinner. */
    var busyWith by remember { mutableStateOf<String?>(null) }
    val scope = rememberCoroutineScope()
    val clipboard = LocalClipboardManager.current

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

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Conduit") },
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
                    onSendClipboard = {
                        val text = clipboard.getText()?.text
                        if (text.isNullOrEmpty()) {
                            node.toast.value = "Clipboard has no text"
                        } else {
                            node.sendClipboard(peer.deviceId, text)
                            node.toast.value = "Clipboard sent to ${peer.name}"
                        }
                    },
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
        }
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
    onSendClipboard: () -> Unit,
) {
    ElevatedCard(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
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
                isConnected -> {
                    FilledTonalButton(onClick = onSendClipboard) { Text("Clipboard") }
                    Spacer(Modifier.width(8.dp))
                    Button(onClick = onControl) { Text("Control") }
                }
                else -> Button(onClick = onConnect) { Text("Connect") }
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
