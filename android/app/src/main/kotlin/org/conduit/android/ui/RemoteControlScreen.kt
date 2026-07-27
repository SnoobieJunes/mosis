package org.conduit.android.ui

import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import org.conduit.android.capability.BluetoothHidController

/**
 * The trackpad/keyboard surface with the Phase 5 mode switch (spec §9 Phase 5
 * step 6): "MOSIS peer" drives a paired device over our protocol; "Bluetooth
 * HID" turns this phone into a REAL Bluetooth keyboard+trackpad to ANY host —
 * an iPad or a TV with no MOSIS installed. Same gestures, two very different
 * outputs.
 */
enum class ControlMode { CONDUIT_PEER, BLUETOOTH_HID }

@Composable
fun RemoteControlScreen(
    connectedHost: String?,
    onMove: (dx: Double, dy: Double) -> Unit,
    onClick: () -> Unit,
    onRightClick: () -> Unit = {},
    onScroll: (dx: Double, dy: Double) -> Unit = { _, _ -> },
    onText: (String) -> Unit = {},
    onSpecialKey: (key: String, modifiers: List<String>) -> Unit = { _, _ -> },
    onMedia: (String) -> Unit = {},
    hidMode: BluetoothHidController? = null,
) {
    var mode by remember { mutableStateOf(ControlMode.CONDUIT_PEER) }
    val hidState by (hidMode?.state ?: remember { kotlinx.coroutines.flow.MutableStateFlow(null) })
        .collectAsState()
    var typed by remember { mutableStateOf("") }
    var modifiers by remember { mutableStateOf(setOf<String>()) }

    // Bluetooth HID registers a system-wide peripheral profile; only hold it
    // while the user is actually in that mode.
    DisposableEffect(mode) {
        if (mode == ControlMode.BLUETOOTH_HID) hidMode?.start()
        onDispose { if (mode == ControlMode.BLUETOOTH_HID) hidMode?.stop() }
    }

    /** Routes a gesture to whichever output the mode selects. */
    fun move(dx: Double, dy: Double) {
        if (mode == ControlMode.BLUETOOTH_HID) hidMode?.move(dx.toInt(), dy.toInt()) else onMove(dx, dy)
    }
    fun click() {
        if (mode == ControlMode.BLUETOOTH_HID) hidMode?.click() else onClick()
    }

    Column(Modifier.fillMaxSize().padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            SegmentedButton(
                selected = mode == ControlMode.CONDUIT_PEER,
                onClick = { mode = ControlMode.CONDUIT_PEER },
                shape = SegmentedButtonDefaults.itemShape(0, 2),
            ) { Text("MOSIS peer") }
            SegmentedButton(
                selected = mode == ControlMode.BLUETOOTH_HID,
                onClick = { mode = ControlMode.BLUETOOTH_HID },
                enabled = hidMode?.isSupported() == true,
                shape = SegmentedButtonDefaults.itemShape(1, 2),
            ) { Text("Bluetooth HID") }
        }

        Text(
            when (mode) {
                ControlMode.CONDUIT_PEER ->
                    connectedHost?.let { "Driving $it over MOSIS." } ?: "Driving the connected device."
                ControlMode.BLUETOOTH_HID -> hidState
                    ?: "Pair this phone as a Bluetooth keyboard on the host, then control it here. Nothing needs to be installed there."
            },
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Surface(
            Modifier.fillMaxWidth().weight(1f).clip(RoundedCornerShape(16.dp)),
            color = MaterialTheme.colorScheme.surfaceVariant,
        ) {
            Box(
                Modifier.fillMaxSize()
                    .pointerInput(mode) {
                        detectDragGestures { change, drag ->
                            change.consume()
                            move(drag.x.toDouble() * 1.6, drag.y.toDouble() * 1.6)
                        }
                    }
                    .pointerInput(mode) {
                        detectTapGestures(
                            onTap = { click() },
                            // Long press is the only unambiguous right-click on
                            // a touch surface with no second button.
                            onLongPress = {
                                if (mode == ControlMode.BLUETOOTH_HID) hidMode?.rightClick() else onRightClick()
                            },
                        )
                    },
                contentAlignment = androidx.compose.ui.Alignment.Center,
            ) {
                Text(
                    "Drag to move · tap to click · long-press right-clicks",
                    color = Color.Gray,
                )
            }
        }

        // Scroll and arrows: a trackpad with no scroll can't read a web page,
        // which is most of what couch-mode remote control is for.
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilledTonalButton(onClick = { scrollBy(mode, hidMode, onScroll, -120.0) }) { Text("Scroll ↑") }
            FilledTonalButton(onClick = { scrollBy(mode, hidMode, onScroll, 120.0) }) { Text("Scroll ↓") }
            Spacer(Modifier.weight(1f))
            FilledTonalButton(onClick = { onMedia("toggle") }) { Text("⏯") }
        }

        if (mode == ControlMode.CONDUIT_PEER) {
            KeyboardRow(
                typed = typed,
                onTypedChange = { old, new ->
                    typed = new
                    if (new.length > old.length) {
                        val added = new.takeLast(new.length - old.length)
                        onText(added)
                    }
                },
                modifiers = modifiers,
                onToggleModifier = { m ->
                    modifiers = if (m in modifiers) modifiers - m else modifiers + m
                },
                onSpecialKey = { key ->
                    onSpecialKey(key, modifiers.toList())
                    modifiers = emptySet()
                },
            )
        }
    }
}

private fun scrollBy(
    mode: ControlMode,
    hid: BluetoothHidController?,
    onScroll: (Double, Double) -> Unit,
    dy: Double,
) {
    if (mode == ControlMode.BLUETOOTH_HID) hid?.scroll(if (dy < 0) 1 else -1) else onScroll(0.0, dy)
}

@Composable
private fun KeyboardRow(
    typed: String,
    onTypedChange: (old: String, new: String) -> Unit,
    modifiers: Set<String>,
    onToggleModifier: (String) -> Unit,
    onSpecialKey: (String) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (m in listOf("shift" to "⇧", "control" to "⌃", "option" to "⌥", "command" to "⌘")) {
                FilterChip(
                    selected = m.first in modifiers,
                    onClick = { onToggleModifier(m.first) },
                    label = { Text(m.second) },
                )
            }
        }
        OutlinedTextField(
            value = typed,
            onValueChange = { onTypedChange(typed, it) },
            label = { Text("Type to the remote device") },
            singleLine = true,
            keyboardActions = KeyboardActions(onDone = { onSpecialKey("return") }),
            modifier = Modifier.fillMaxWidth(),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            for (key in listOf("backspace" to "⌫", "tab" to "⇥", "escape" to "esc",
                               "left" to "←", "up" to "↑", "down" to "↓", "right" to "→")) {
                FilledTonalButton(onClick = { onSpecialKey(key.first) }) { Text(key.second) }
            }
        }
    }
}
