package org.conduit.android

import android.util.Log

/**
 * One logcat tag for everything a failed pairing needs explained.
 *
 * Added 2026-08-17. The app had two `Log` calls in the entire module, the
 * pair/connect path collapsed every failure into a 3.5-second snackbar, and
 * `docs/DEVICE_CHECKLIST.md` §7 — the Android script — gave no log-capture
 * command at all while §0 handed macOS a `log stream` one-liner. So the first
 * contributor whose pairing failed would have had nothing to report, on the
 * one gate the project most wants someone to pass.
 *
 * Read it with:
 *
 *     adb logcat -s MOSIS:V
 *     adb logcat --pid=$(adb shell pidof org.conduit.android)
 *
 * Deliberately not a full logging framework, and deliberately not chatty: this
 * is the pairing/session narrative (discovery, bind, dial, handshake, PAIR_*
 * steps, capabilities, close reason), not per-frame tracing. Nothing here logs
 * file contents, clipboard text, keystrokes or frame data — the material this
 * app exists to move. Public keys are truncated to 16 hex.
 */
internal object Diag {
    const val TAG = "MOSIS"

    fun log(message: String) {
        Log.i(TAG, message)
    }

    fun warn(message: String, error: Throwable? = null) {
        if (error == null) Log.w(TAG, message) else Log.w(TAG, message, error)
    }
}
