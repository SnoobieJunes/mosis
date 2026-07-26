package org.conduit.android.capability

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import org.conduit.android.ScreenShareService

/**
 * The two steps between "a peer asked to see this screen" and pixels moving.
 *
 * MediaProjection is deliberately hard to start: the system consent dialog is
 * mandatory *every session* (spec pitfall) and can only be raised from an
 * Activity, while from Android 14 the projection itself must be created inside
 * a foreground service that already declared the `mediaProjection` type. Those
 * two requirements are in different processes' worth of lifecycle, so the
 * Activity only collects consent and [ScreenShareService] redeems it.
 */
object ScreenShareStarter {

    /** The Intent an Activity launches to ask for consent. */
    fun consentIntent(context: Context): Intent =
        (context.getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager)
            .createScreenCaptureIntent()

    /**
     * Hands a granted consent result to the capture service. Returns null when
     * the share is starting, or a reason to show.
     */
    fun start(context: Context, peerId: String, resultCode: Int, data: Intent?): String? {
        if (resultCode != Activity.RESULT_OK || data == null) {
            return "Screen sharing needs permission — it was declined."
        }
        ScreenShareService.start(context, peerId, resultCode, data)
        return null
    }

    fun stop(context: Context) = ScreenShareService.stop(context)
}
