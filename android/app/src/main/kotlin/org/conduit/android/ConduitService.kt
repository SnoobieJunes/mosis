package org.conduit.android

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Foreground service that keeps the node alive so transfers and screen streams
 * survive the app going to the background (spec §9 Phase 5). Started when the
 * user first pairs/connects; stopped from the notification.
 */
class ConduitService : Service() {
    override fun onCreate() {
        super.onCreate()
        val runtime = ConduitRuntime.ensure(this)
        runtime.node.start()
        // Name the type explicitly rather than inheriting whatever the manifest
        // declares: this service is the always-on node, and it must never claim
        // mediaProjection (see the manifest comment — Android 14 rejects that
        // before consent exists). Screen capture is ScreenShareService's job.
        startForeground(
            NOTIF_ID, buildNotification(),
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE,
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY
    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): Notification {
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            mgr.createNotificationChannel(
                NotificationChannel(CHANNEL, "MOSIS", NotificationManager.IMPORTANCE_LOW)
            )
        }
        return NotificationCompat.Builder(this, CHANNEL)
            .setContentTitle("MOSIS is running")
            .setContentText("Connected devices can exchange files, input, and screens")
            .setSmallIcon(android.R.drawable.stat_sys_data_bluetooth)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL = "conduit.service"
        private const val NOTIF_ID = 1
        fun start(context: Context) {
            val i = Intent(context, ConduitService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(i)
            else context.startService(i)
        }
    }
}
