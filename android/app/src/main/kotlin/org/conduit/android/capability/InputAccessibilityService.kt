package org.conduit.android.capability

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import org.conduit.android.ConduitRuntime
import org.conduit.core.wire.Json
import org.conduit.core.wire.asObj
import org.conduit.core.wire.opt
import org.conduit.core.wire.str

/**
 * Input RECEIVER (spec §9 Phase 5 step 5): a peer controls this Android device.
 * AccessibilityService#dispatchGesture is the only sanctioned injection path on
 * Android; it takes absolute coordinates, so relative moves are accumulated
 * onto a virtual cursor and absolute ones (`nx`/`ny`) are used directly.
 *
 * Consent-gated by design: the user must enable this service in system settings
 * (Play review scrutiny — spec pitfall), and while a peer is controlling, the
 * app shows a persistent notification with an instant revoke, mirroring the
 * macOS indicator invariant.
 *
 * **What Android cannot do, stated rather than faked.** There is no general
 * key-injection API for a third-party accessibility service. Text is delivered
 * by setting it on the focused editable node, and the special keys that exist
 * as global actions (back, home, recents) are mapped to those. Anything else —
 * arrow keys, function keys, modifier chords — has no route at all and is
 * refused loudly rather than silently dropped. That is a platform wall, not a
 * missing feature; the honest version of "Android keyboard injection" is a
 * short list that works and a clear statement of what doesn't.
 */
class InputAccessibilityService : AccessibilityService() {

    private var cursorX = 500f
    private var cursorY = 800f

    override fun onServiceConnected() {
        instance = this
        ConduitRuntime.instance?.onInputReceiverAvailable(true)
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        ConduitRuntime.instance?.onInputReceiverAvailable(false)
        super.onDestroy()
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) { /* receiver-only */ }
    override fun onInterrupt() {}

    /** Applies one INPUT_EVENT from a controlling peer. */
    fun inject(payload: Json) {
        val e = payload.asObj()
        when (e.getValue("kind").str()) {
            "move" -> {
                // Absolute wins when present: the controller is looking at a
                // live view of this screen and named a position on it, which is
                // strictly better information than a delta. `dx`/`dy` are still
                // there for receivers that predate nx/ny — this one doesn't.
                val nx = num(e, "nx")
                val ny = num(e, "ny")
                if (nx != null && ny != null) {
                    cursorX = (nx * screenW()).coerceIn(0f, screenW())
                    cursorY = (ny * screenH()).coerceIn(0f, screenH())
                } else {
                    cursorX = (cursorX + (num(e, "dx") ?: 0f)).coerceIn(0f, screenW())
                    cursorY = (cursorY + (num(e, "dy") ?: 0f)).coerceIn(0f, screenH())
                }
            }
            "scroll" -> {
                val dy = num(e, "dy") ?: 0f
                swipe(cursorX, cursorY, cursorX, cursorY - dy, 120)
            }
            "click" -> {
                // Android has one pointer and no button concept, so a right
                // click is a long press — the gesture that opens a context menu.
                val isSecondary = e.opt("button")?.str() == "right"
                // Only act on a complete press. A bare "down" from a drag would
                // otherwise fire a tap per motion sample.
                val action = e.opt("action")?.str() ?: "tap"
                if (action == "up") return
                if (isSecondary) longPress(cursorX, cursorY) else tap(cursorX, cursorY)
            }
            "key" -> injectKey(e)
        }
    }

    /**
     * Keys, within what the platform actually permits.
     *
     * A key-up is ignored: everything below is a complete action, so applying it
     * on both edges would type twice.
     */
    private fun injectKey(e: Map<String, Json>) {
        if (e.opt("action")?.str() == "up") return
        val text = e.opt("text")?.str()
        if (text != null) {
            typeIntoFocusedField(text)
            return
        }
        when (e.opt("key")?.str()) {
            "escape" -> performGlobalAction(GLOBAL_ACTION_BACK)
            "backspace" -> backspaceFocusedField()
            "return", "enter" -> {
                val node = focusedEditable()
                if (node != null) node.performAction(AccessibilityNodeInfo.ACTION_CLICK)
                else performGlobalAction(GLOBAL_ACTION_HOME)
            }
            "home" -> performGlobalAction(GLOBAL_ACTION_HOME)
            "page_down" -> performGlobalAction(GLOBAL_ACTION_RECENTS)
            else -> ConduitRuntime.instance?.onInputUnsupported(
                "Android can't inject that key — only text, Back, Home and Enter are available to an accessibility service."
            )
        }
    }

    /**
     * Appends text to the focused editable node.
     *
     * `ACTION_SET_TEXT` replaces the whole field, so the existing contents are
     * read first and the new characters appended; otherwise typing "hello" one
     * character at a time would leave "o".
     */
    private fun typeIntoFocusedField(text: String) {
        val node = focusedEditable() ?: run {
            ConduitRuntime.instance?.onInputUnsupported("Tap a text field on this device first — Android can only type into a focused field.")
            return
        }
        val existing = node.text?.toString() ?: ""
        val args = Bundle().apply {
            putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, existing + text)
        }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    private fun backspaceFocusedField() {
        val node = focusedEditable() ?: return
        val existing = node.text?.toString() ?: ""
        if (existing.isEmpty()) return
        val args = Bundle().apply {
            putCharSequence(
                AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE,
                existing.dropLast(1),
            )
        }
        node.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)
    }

    private fun focusedEditable(): AccessibilityNodeInfo? =
        findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.takeIf { it.isEditable }

    private fun tap(x: Float, y: Float) {
        val path = Path().apply { moveTo(x, y) }
        // 20 ms still registers reliably as a tap; shorter stroke = lower
        // click-to-effect latency (the gesture only completes when it ends).
        val stroke = GestureDescription.StrokeDescription(path, 0, 20)
        dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
    }

    /** Long press — Android's context-menu gesture, i.e. its right click. */
    private fun longPress(x: Float, y: Float) {
        val path = Path().apply { moveTo(x, y) }
        val stroke = GestureDescription.StrokeDescription(path, 0, 600)
        dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
    }

    private fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long) {
        val path = Path().apply { moveTo(x1, y1); lineTo(x2, y2) }
        val stroke = GestureDescription.StrokeDescription(path, 0, durationMs)
        dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
    }

    private fun num(e: Map<String, Json>, key: String): Float? =
        (e[key] as? Json.Num)?.literal?.toFloatOrNull()

    private fun screenW() = resources.displayMetrics.widthPixels.toFloat()
    private fun screenH() = resources.displayMetrics.heightPixels.toFloat()

    companion object {
        @Volatile var instance: InputAccessibilityService? = null
    }
}
