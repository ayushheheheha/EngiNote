package com.engikode.enginote

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/** What the activity and the service hand each other. They live in one process, so this is plain memory. */
object Session {
    /** The recording in progress, if any. */
    var recorder: Recorder? = null

    /** What the service needs to begin a recording; set by the activity just before it starts the service. */
    class Pending(val params: Recorder.Params, val mic: Mic, val code: Int, val data: Intent, val onStarted: (Recorder?, String?) -> Unit)
    var pending: Pending? = null

    /** The notification's Stop button: set by the activity, which stops the recording the usual way. */
    var stopRequested: (() -> Unit)? = null
}

/**
 * A recording of the screen must run in a foreground service (with a notification), or Android
 * will not hand over the screen. The service does nothing else: the recording itself is Recorder.
 */
class RecordService : Service() {
    companion object {
        const val STOP = "com.engikode.enginote.STOP"
        private const val CHANNEL = "recording"
        private const val ID = 1
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) {
            val stop = Session.stopRequested
            if (stop != null) stop() else stopSelf()
            return START_NOT_STICKY
        }
        val pending = Session.pending
        Session.pending = null
        if (pending == null) {
            stopSelf()
            return START_NOT_STICKY
        }

        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Screen recording", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, packageManager.getLaunchIntentForPackage(packageName), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, RecordService::class.java).setAction(STOP), PendingIntent.FLAG_IMMUTABLE)
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle("EngiNote is recording the screen")
            .setContentIntent(open)
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .setOngoing(true)
            .build()
        startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)

        // Only now, in a foreground service of the right kind, may the screen be taken.
        var error: String? = null
        var recorder: Recorder? = null
        try {
            val projection = (getSystemService(MEDIA_PROJECTION_SERVICE) as MediaProjectionManager).getMediaProjection(pending.code, pending.data)
            val made = Recorder(applicationContext, pending.mic)
            error = made.start(projection, pending.params)
            if (error == null) recorder = made
        } catch (e: Exception) {
            error = e.message ?: e.toString()
        }
        Session.recorder = recorder
        if (recorder == null) stopSelf()
        Handler(Looper.getMainLooper()).post { pending.onStarted(recorder, error) }
        return START_NOT_STICKY
    }
}
