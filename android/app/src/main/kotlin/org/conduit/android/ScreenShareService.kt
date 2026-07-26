package org.conduit.android

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.hardware.display.DisplayManager
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.IBinder
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import org.conduit.android.capability.ScreenProjectionSource

/**
 * Runs the MediaProjection screen capture (AND-2).
 *
 * It is a **separate** foreground service from [ConduitService] because Android
 * 14 requires that a service claiming `mediaProjection` type only start *after*
 * the user has granted a projection — so the always-on node service must not
 * declare that type, and the projection must be created from inside a service
 * that has already called `startForeground` with it. Getting this wrong throws
 * a `SecurityException` at a point where the only symptom is "sharing does
 * nothing", which is the class of failure this project has spent the most time
 * removing.
 *
 * The consent `Intent` therefore travels here rather than being redeemed in the
 * Activity: this is the one place both conditions hold at once.
 */
class ScreenShareService : Service() {
    private var projection: MediaProjection? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) return START_NOT_STICKY
        if (intent.action == ACTION_STOP) {
            stopSharing()
            return START_NOT_STICKY
        }
        val peerId = intent.getStringExtra(EXTRA_PEER_ID) ?: return START_NOT_STICKY
        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0)
        val data: Intent? = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION") intent.getParcelableExtra(EXTRA_RESULT_DATA)
        }
        if (data == null) return START_NOT_STICKY

        // Foreground FIRST, with the projection type, THEN take the projection.
        startForeground(
            NOTIF_ID, buildNotification(),
            if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION else 0,
        )

        val runtime = ConduitRuntime.instance ?: return stopAndReport("MOSIS isn't running.")
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val projection = try {
            manager.getMediaProjection(resultCode, data)
        } catch (e: SecurityException) {
            return stopAndReport("Android refused screen capture: ${e.message}")
        } ?: return stopAndReport("Screen capture was not granted.")
        this.projection = projection

        val bounds = (getSystemService(Context.WINDOW_SERVICE) as WindowManager).maximumWindowMetrics.bounds
        val (width, height) = fit(bounds.width(), bounds.height(), MAX_LONG_EDGE)
        val source = ScreenProjectionSource(
            projection = projection,
            displayManager = getSystemService(Context.DISPLAY_SERVICE) as DisplayManager,
            width = width, height = height,
            dpi = resources.configuration.densityDpi, fps = FPS,
            useHevc = false,   // H.264: what every viewer here can decode
        )
        // The user can stop the capture from the system's own indicator; if
        // that happens the share must end rather than claim to be live.
        projection.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                runtime.node.screens.stopSourcing()
                stopSelf()
            }
        }, null)

        runtime.node.screens.startSourcing(
            peerId = peerId, source = source, width = width, height = height, fps = FPS,
            deviceName = Build.MODEL ?: "Android", useHevc = false,
        )
        return START_NOT_STICKY
    }

    private fun stopAndReport(reason: String): Int {
        ConduitRuntime.instance?.node?.toast?.value = reason
        stopSelf()
        return START_NOT_STICKY
    }

    private fun stopSharing() {
        ConduitRuntime.instance?.node?.screens?.stopSourcing()
        projection?.stop()
        projection = null
        stopSelf()
    }

    override fun onDestroy() {
        projection?.stop()
        projection = null
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        val mgr = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        mgr.createNotificationChannel(
            NotificationChannel(CHANNEL, "Screen sharing", NotificationManager.IMPORTANCE_LOW)
        )
        val stop = PendingIntentCompat.service(
            this, Intent(this, ScreenShareService::class.java).setAction(ACTION_STOP)
        )
        return NotificationCompat.Builder(this, CHANNEL)
            .setContentTitle("Sharing your screen")
            .setContentText("Another device is watching this screen")
            .setSmallIcon(android.R.drawable.ic_menu_view)
            .setOngoing(true)
            .addAction(0, "Stop", stop)
            .build()
    }

    companion object {
        private const val CHANNEL = "mosis.screenshare"
        private const val NOTIF_ID = 2
        private const val EXTRA_PEER_ID = "peer_id"
        private const val EXTRA_RESULT_CODE = "result_code"
        private const val EXTRA_RESULT_DATA = "result_data"
        const val ACTION_STOP = "org.conduit.android.STOP_SCREEN_SHARE"
        /** Long edge cap: a 1440×3120 phone costs far more bitrate and encoder
         *  memory than any viewer can use. */
        private const val MAX_LONG_EDGE = 1920
        private const val FPS = 30

        fun start(context: Context, peerId: String, resultCode: Int, data: Intent) {
            val intent = Intent(context, ScreenShareService::class.java)
                .putExtra(EXTRA_PEER_ID, peerId)
                .putExtra(EXTRA_RESULT_CODE, resultCode)
                .putExtra(EXTRA_RESULT_DATA, data)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            context.startService(
                Intent(context, ScreenShareService::class.java).setAction(ACTION_STOP)
            )
        }

        /** Scales to a maximum long edge, rounded to even (codec requirement). */
        fun fit(width: Int, height: Int, maxLongEdge: Int): Pair<Int, Int> {
            val longEdge = maxOf(width, height)
            if (longEdge <= maxLongEdge || longEdge == 0) return even(width) to even(height)
            val scale = maxLongEdge.toDouble() / longEdge
            return even((width * scale).toInt()) to even((height * scale).toInt())
        }

        private fun even(v: Int) = maxOf(2, v / 2 * 2)
    }
}

/** `PendingIntent.getService` with the mutability flag Android 12+ requires. */
private object PendingIntentCompat {
    fun service(context: Context, intent: Intent) = android.app.PendingIntent.getService(
        context, 0, intent,
        android.app.PendingIntent.FLAG_UPDATE_CURRENT or android.app.PendingIntent.FLAG_IMMUTABLE,
    )
}
