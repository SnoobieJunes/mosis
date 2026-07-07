package org.conduit.android.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlinx.coroutines.launch
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
        val runtime = ConduitRuntime.ensure(this)
        ConduitService.start(this)
        setContent { MaterialTheme(colorScheme = darkColorScheme()) { DevicesScreen(runtime) } }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevicesScreen(runtime: ConduitRuntime) {
    val node = runtime.node
    val discovered by node.discovered.collectAsStateWithLifecycle()
    val pinned by node.pinned.collectAsStateWithLifecycle()
    val toast by node.toast.collectAsStateWithLifecycle()
    var acceptPairing by remember { mutableStateOf(false) }
    var prompt by remember { mutableStateOf<Pair<PairPrompt, (Boolean) -> Unit>?>(null) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) {
        node.confirmPairing = { p -> suspendCoroutine { cont -> prompt = p to { ok -> prompt = null; cont.resume(ok) } } }
    }
    LaunchedEffect(acceptPairing) { node.pairingEnabled = acceptPairing }

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
    ) { pad ->
        LazyColumn(Modifier.padding(pad).fillMaxSize(), contentPadding = PaddingValues(16.dp)) {
            item { SectionHeader("My devices") }
            if (pinned.isEmpty()) item { Hint("No paired devices yet. Turn on Accept pairing on one device, then tap the other under Nearby.") }
            items(pinned) { peer ->
                PairedRow(peer.name, peer.deviceClass) {
                    scope.launch {
                        node.discoveredFor(peer.name)?.let { node.connect(peer, it.host, it.port) }
                    }
                }
            }
            item { Spacer(Modifier.height(16.dp)); SectionHeader("Nearby") }
            items(discovered.filter { d -> pinned.none { it.deviceId == d.deviceId } }) { d ->
                NearbyRow(d.name, d.deviceClass) { scope.launch { node.pair(d.host, d.port) } }
            }
            toast?.let { item { Spacer(Modifier.height(20.dp)); Hint(it) } }
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
private fun PairedRow(name: String, deviceClass: String, onConnect: () -> Unit) {
    ElevatedCard(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        Row(Modifier.padding(16.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(name, style = MaterialTheme.typography.titleMedium)
                Text(deviceClass, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Button(onClick = onConnect) { Text("Connect") }
        }
    }
}

@Composable
private fun NearbyRow(name: String, deviceClass: String, onPair: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(name)
            Text("Not paired · $deviceClass", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        FilledTonalButton(onClick = onPair) { Text("Pair") }
    }
}
