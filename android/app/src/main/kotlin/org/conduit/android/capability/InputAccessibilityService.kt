package org.conduit.android.capability

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.graphics.Path
import android.view.accessibility.AccessibilityEvent
import org.conduit.android.ConduitRuntime
import org.conduit.core.wire.Json
import org.conduit.core.wire.asObj
import org.conduit.core.wire.str

/**
 * Input RECEIVER (spec §9 Phase 5 step 5): a peer controls this Android device.
 * AccessibilityService#dispatchGesture is the only sanctioned injection path on
 * Android; it takes absolute coordinates, so we keep a virtual cursor and map
 * incoming relative move/click INPUT_EVENTs onto taps and swipes.
 *
 * Consent-gated by design: the user must enable this service in system settings
 * (Play review scrutiny — spec pitfall), and while a peer is controlling, the
 * app shows a persistent notification with an instant revoke, mirroring the
 * macOS indicator invariant.
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
                val dx = (e["dx"] as? Json.Num)?.literal?.toFloat() ?: 0f
                val dy = (e["dy"] as? Json.Num)?.literal?.toFloat() ?: 0f
                cursorX = (cursorX + dx).coerceIn(0f, screenW())
                cursorY = (cursorY + dy).coerceIn(0f, screenH())
            }
            "scroll" -> {
                val dy = (e["dy"] as? Json.Num)?.literal?.toFloat() ?: 0f
                swipe(cursorX, cursorY, cursorX, cursorY - dy, 120)
            }
            "click" -> tap(cursorX, cursorY)
        }
    }

    private fun tap(x: Float, y: Float) {
        val path = Path().apply { moveTo(x, y) }
        // 20 ms still registers reliably as a tap; shorter stroke = lower
        // click-to-effect latency (the gesture only completes when it ends).
        val stroke = GestureDescription.StrokeDescription(path, 0, 20)
        dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
    }

    private fun swipe(x1: Float, y1: Float, x2: Float, y2: Float, durationMs: Long) {
        val path = Path().apply { moveTo(x1, y1); lineTo(x2, y2) }
        val stroke = GestureDescription.StrokeDescription(path, 0, durationMs)
        dispatchGesture(GestureDescription.Builder().addStroke(stroke).build(), null, null)
    }

    private fun screenW() = resources.displayMetrics.widthPixels.toFloat()
    private fun screenH() = resources.displayMetrics.heightPixels.toFloat()

    companion object {
        @Volatile var instance: InputAccessibilityService? = null
    }
}
