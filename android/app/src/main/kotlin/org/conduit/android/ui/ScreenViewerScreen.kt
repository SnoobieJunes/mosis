package org.conduit.android.ui

import android.view.SurfaceHolder
import android.view.SurfaceView
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.conduit.android.ConduitRuntime
import org.conduit.android.capability.ScreenSessions

/**
 * Watching another device's screen on Android — "cast my Mac to a tablet",
 * natively. The `SurfaceView` is the decoder's output target; frames reach it
 * through [ScreenSessions] and [org.conduit.android.capability.ScreenDecoder].
 *
 * The browser watch page has always been able to do this over HLS, but several
 * seconds behind. This path is the low-latency one, and it is the only one that
 * can also carry input back.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScreenViewerRoute(runtime: ConduitRuntime, onBack: () -> Unit) {
    val node = runtime.node
    val viewing by node.screens.viewing.collectAsStateWithLifecycle()
    val frames by node.screens.decodedFrames.collectAsStateWithLifecycle()
    val session = viewing

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(session?.sourceName ?: "Screen") },
                navigationIcon = { TextButton(onClick = onBack) { Text("Back") } },
                actions = {
                    TextButton(onClick = { node.screens.stopViewing(); onBack() }) { Text("Stop") }
                },
            )
        },
    ) { pad ->
        Box(
            Modifier.padding(pad).fillMaxSize(),
            contentAlignment = Alignment.Center,
        ) {
            if (session == null) {
                Text("The stream ended.")
                return@Box
            }
            AndroidView(
                factory = { context ->
                    SurfaceView(context).apply {
                        holder.addCallback(object : SurfaceHolder.Callback {
                            override fun surfaceCreated(holder: SurfaceHolder) {
                                node.screens.attachSurface(holder.surface)
                            }
                            override fun surfaceChanged(h: SurfaceHolder, f: Int, w: Int, ht: Int) {}
                            override fun surfaceDestroyed(holder: SurfaceHolder) {}
                        })
                    }
                },
                modifier = Modifier.fillMaxSize(),
            )
            // Distinguish "waiting for the first frame" from "black screen",
            // which is the difference between patience and a bug report.
            if (frames == 0L) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    CircularProgressIndicator()
                    Spacer(Modifier.height(12.dp))
                    Text(
                        "Waiting for video from ${session.sourceName}…",
                        color = Color.White,
                        style = MaterialTheme.typography.bodyMedium,
                    )
                }
            }
        }
    }
}
