package org.conduit.android.capability

import android.app.Notification
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import org.conduit.android.ConduitRuntime

/**
 * Notification SOURCE (spec §9 Phase 5 step 5): mirror this device's
 * notifications to paired peers that can display them (Apple apps advertise
 * notify-show). Per-app filtering lives in [ConduitRuntime]; the user enables
 * this listener in system settings, and its own app's notifications are skipped.
 */
class NotificationSourceService : NotificationListenerService() {

    override fun onListenerConnected() {
        instance = this
        ConduitRuntime.instance?.onNotificationSourceAvailable(true)
    }

    override fun onListenerDisconnected() {
        if (instance === this) instance = null
        ConduitRuntime.instance?.onNotificationSourceAvailable(false)
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        val runtime = ConduitRuntime.instance ?: return
        if (sbn.packageName == packageName) return                 // don't echo our own
        if (!runtime.shouldMirror(sbn.packageName)) return          // per-app filter
        val extras = sbn.notification.extras
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString().orEmpty()
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
        if (title.isEmpty() && text.isEmpty()) return
        val appLabel = try {
            val pm = packageManager
            pm.getApplicationLabel(pm.getApplicationInfo(sbn.packageName, 0)).toString()
        } catch (_: Exception) { sbn.packageName }
        runtime.mirrorNotification(appLabel, title, text, sbn.key)
    }

    companion object {
        @Volatile var instance: NotificationSourceService? = null
    }
}
