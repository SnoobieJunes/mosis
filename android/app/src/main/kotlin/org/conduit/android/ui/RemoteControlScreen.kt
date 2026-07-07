package org.conduit.android.ui

import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp

/**
 * The trackpad/keyboard surface with the Phase 5 mode switch (spec §9 Phase 5
 * step 6): "Conduit peer" drives a paired device over our protocol; "Bluetooth
 * HID" turns this phone into a REAL Bluetooth keyboard+trackpad to ANY host —
 * an iPad or a TV with no Conduit installed. Same gestures, two very different
 * outputs.
 */
enum class ControlMode { CONDUIT_PEER, BLUETOOTH_HID }

@Composable
fun RemoteControlScreen(
    connectedHost: String?,
    onMove: (dx: Double, dy: Double) -> Unit,
    onClick: () -> Unit,
    onModeChange: (ControlMode) -> Unit,
) {
    var mode by remember { mutableStateOf(ControlMode.CONDUIT_PEER) }

    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            SegmentedButton(
                selected = mode == ControlMode.CONDUIT_PEER,
                onClick = { mode = ControlMode.CONDUIT_PEER; onModeChange(mode) },
                shape = SegmentedButtonDefaults.itemShape(0, 2),
            ) { Text("Conduit peer") }
            SegmentedButton(
                selected = mode == ControlMode.BLUETOOTH_HID,
                onClick = { mode = ControlMode.BLUETOOTH_HID; onModeChange(mode) },
                shape = SegmentedButtonDefaults.itemShape(1, 2),
            ) { Text("Bluetooth HID") }
        }

        Text(
            when (mode) {
                ControlMode.CONDUIT_PEER -> "Driving the connected Conduit device."
                ControlMode.BLUETOOTH_HID -> connectedHost?.let { "Acting as a Bluetooth keyboard/trackpad for $it — no app needed on it." }
                    ?: "Pair this phone as a Bluetooth device on the host, then control it here."
            },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Surface(
            Modifier.fillMaxWidth().weight(1f).clip(RoundedCornerShape(16.dp)),
            color = MaterialTheme.colorScheme.surfaceVariant,
        ) {
            Box(
                Modifier.fillMaxSize().pointerInput(Unit) {
                    detectDragGestures { change, drag ->
                        change.consume()
                        onMove(drag.x.toDouble() * 1.6, drag.y.toDouble() * 1.6)
                    }
                }.pointerInput(Unit) { detectTapGestures(onTap = { onClick() }) },
                contentAlignment = androidx.compose.ui.Alignment.Center,
            ) {
                Text("Drag to move · tap to click", color = Color.Gray)
            }
        }
    }
}
