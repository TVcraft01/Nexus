package dev.nexus.nexus

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Takes one screenshot of the phone through MediaProjection and stops.
 *
 * It is a foreground service because Android 14 stopped letting an app open a
 * projection without one: since API 34 `getMediaProjection()` throws unless a
 * service of type `mediaProjection` is already in the foreground, and the
 * platform kills the process if the notification does not appear within a few
 * seconds of the start call. So the order below is load-bearing — foreground
 * first, projection second — and it is why the capture is a service rather
 * than a few lines in the activity.
 *
 * Deliberately a *single frame*: the virtual display is released, the reader is
 * closed, the projection is stopped and the service stops itself before the
 * path is handed back. Nothing keeps mirroring the screen after the shutter,
 * which is the difference between "take a screenshot" and "screen share".
 */
class ScreenCaptureService : Service() {
    companion object {
        private const val TAG = "NexusScreen"
        private const val CHANNEL_ID = "nexus-screen-capture"
        private const val NOTIFICATION_ID = 52130

        const val EXTRA_RESULT_CODE = "resultCode"
        const val EXTRA_RESULT_DATA = "resultData"

        /**
         * Where the answer goes: (path, message). Exactly one is non-null.
         * Set by MainActivity before the service starts; cleared after use.
         * Invoked on the main thread.
         */
        @Volatile
        var onCaptured: ((String?, String?) -> Unit)? = null

        /** True while a capture is in flight, so a second tap cannot stack them. */
        @Volatile
        var running: Boolean = false
            private set

        /** Asks Android to run one capture with the user's projection grant. */
        fun start(context: Context, resultCode: Int, data: Intent) {
            val intent = Intent(context, ScreenCaptureService::class.java).apply {
                putExtra(EXTRA_RESULT_CODE, resultCode)
                putExtra(EXTRA_RESULT_DATA, data)
            }
            try {
                ContextCompat.startForegroundService(context, intent)
            } catch (e: Exception) {
                Log.w(TAG, "foreground service start refused: ${e.message}")
                finish(null, "The screenshot service could not start.")
            }
        }

        /** Answers the pending request once, whatever the outcome. */
        private fun finish(path: String?, message: String?) {
            running = false
            val callback = onCaptured
            onCaptured = null
            Handler(Looper.getMainLooper()).post { callback?.invoke(path, message) }
        }
    }

    private var projection: MediaProjection? = null

    // Android 14 refuses createVirtualDisplay() unless a callback is
    // registered first, so this is not bookkeeping — without it a modern
    // phone throws IllegalStateException instead of taking the picture. It
    // also carries the case the deadline cannot: the user (or the system)
    // stopping the projection out from under us.
    private var projectionCallback: MediaProjection.Callback? = null
    private var display: VirtualDisplay? = null
    private var reader: ImageReader? = null
    private var thread: HandlerThread? = null
    private val answered = AtomicBoolean(false)

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // The notification must exist within a few seconds of the start, or the
        // platform kills the process — post it before anything else.
        startInForeground()

        val resultCode = intent?.getIntExtra(EXTRA_RESULT_CODE, Activity.RESULT_CANCELED)
            ?: Activity.RESULT_CANCELED
        val data = resultData(intent)
        if (data == null || resultCode != Activity.RESULT_OK) {
            answer(null, "Screen capture was not allowed.")
            return START_NOT_STICKY
        }

        running = true
        capture(resultCode, data)

        // Give the frame a deadline. A projection that never delivers one
        // (a locked screen, an OEM that refuses the mirror) must not leave the
        // user staring at a spinner that never resolves.
        Handler(Looper.getMainLooper()).postDelayed({
            if (answered.compareAndSet(false, true)) {
                Log.w(TAG, "no frame arrived within the deadline")
                teardown()
                answer(null, "The screen did not come back in time.")
            }
        }, FRAME_TIMEOUT_MS)

        return START_NOT_STICKY
    }

    /** Reads the granted projection intent on both sides of the API 33 split. */
    private fun resultData(intent: Intent?): Intent? {
        if (intent == null) return null
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(EXTRA_RESULT_DATA)
        }
    }

    private fun capture(resultCode: Int, data: Intent) {
        val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE)
            as MediaProjectionManager
        val granted: MediaProjection? = try {
            manager.getMediaProjection(resultCode, data)
        } catch (e: Exception) {
            Log.e(TAG, "projection refused", e)
            null
        }
        if (granted == null) {
            answer(null, "The screen could not be mirrored.")
            return
        }
        projection = granted
        val callback = object : MediaProjection.Callback() {
            override fun onStop() {
                if (answered.compareAndSet(false, true)) {
                    Log.i(TAG, "the projection was stopped before a frame arrived")
                    teardown()
                    answer(null, "Screen capture was stopped.")
                }
            }
        }
        projectionCallback = callback
        try {
            granted.registerCallback(callback, Handler(Looper.getMainLooper()))
        } catch (e: Exception) {
            Log.e(TAG, "projection callback refused", e)
            projectionCallback = null
            answer(null, "The screen could not be mirrored.")
            return
        }

        // The real display, not the window: a screenshot is of the phone's
        // screen, and a phone held in landscape is captured as it is held.
        val metrics = resources.displayMetrics
        val width = metrics.widthPixels
        val height = metrics.heightPixels
        val density = metrics.densityDpi
        if (width <= 0 || height <= 0) {
            answer(null, "The screen size could not be read.")
            return
        }

        reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        thread = HandlerThread("nexus-screen-capture").also { it.start() }
        val handler = Handler(thread!!.looper)

        reader!!.setOnImageAvailableListener({ source ->
            if (!answered.compareAndSet(false, true)) {
                source.acquireLatestImage()?.close()
                return@setOnImageAvailableListener
            }
            val image = try {
                source.acquireLatestImage()
            } catch (e: Exception) {
                Log.e(TAG, "frame read failed", e)
                null
            }
            val path = if (image == null) {
                null
            } else {
                try {
                    save(image, width, height)
                } catch (e: Exception) {
                    Log.e(TAG, "frame save failed", e)
                    null
                } finally {
                    image.close()
                }
            }
            teardown()
            answer(path, if (path == null) "The screenshot could not be saved." else null)
        }, handler)

        display = try {
            granted.createVirtualDisplay(
                "nexus-screenshot",
                width,
                height,
                density,
                DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR,
                reader!!.surface,
                null,
                handler,
            )
        } catch (e: Exception) {
            Log.e(TAG, "virtual display refused", e)
            null
        }
        if (display == null) {
            answer(null, "The screen could not be mirrored.")
        }
    }

    /** Writes one captured frame to a PNG in the cache and answers its path. */
    private fun save(image: android.media.Image, width: Int, height: Int): String? {
        val plane = image.planes[0]
        val buffer = plane.buffer
        val pixelStride = plane.pixelStride
        val rowStride = plane.rowStride
        // Frames are padded to the hardware's row stride: a bitmap decoded
        // straight from the buffer would be sheared by that padding.
        val rowPadding = rowStride - pixelStride * width
        val paddedWidth = width + rowPadding / pixelStride

        val padded = Bitmap.createBitmap(paddedWidth, height, Bitmap.Config.ARGB_8888)
        padded.copyPixelsFromBuffer(buffer)
        val bitmap = if (paddedWidth != width) {
            Bitmap.createBitmap(padded, 0, 0, width, height)
        } else {
            padded
        }

        val folder = File(cacheDir, "screenshots").apply { mkdirs() }
        val file = File(folder, "screen-${System.currentTimeMillis()}.png")
        FileOutputStream(file).use { out ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        }
        if (bitmap !== padded) bitmap.recycle()
        padded.recycle()
        Log.i(TAG, "screenshot saved: ${file.absolutePath} (${file.length()} bytes)")
        return file.absolutePath
    }

    /** Lets go of the projection, the display and the reader. Idempotent. */
    private fun teardown() {
        try {
            display?.release()
        } catch (e: Exception) {
            Log.w(TAG, "display release failed: ${e.message}")
        }
        display = null
        try {
            reader?.close()
        } catch (e: Exception) {
            Log.w(TAG, "reader close failed: ${e.message}")
        }
        reader = null
        try {
            val callback = projectionCallback
            if (callback != null) projection?.unregisterCallback(callback)
        } catch (e: Exception) {
            Log.w(TAG, "callback unregister failed: ${e.message}")
        }
        projectionCallback = null
        try {
            projection?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "projection stop failed: ${e.message}")
        }
        projection = null
        thread?.quitSafely()
        thread = null
    }

    /** Hands the answer back and takes the service down. */
    private fun answer(path: String?, message: String?) {
        teardown()
        finish(path, message)
        stopSelf()
    }

    override fun onDestroy() {
        teardown()
        super.onDestroy()
    }

    /** Posts the (brief) notification and promotes the service to foreground. */
    private fun startInForeground() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Screen capture",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Shown while a screenshot is being taken."
                    setShowBadge(false)
                },
            )
        }
        val notification: Notification =
            Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("Taking a screenshot")
                .setContentText("Nexus is saving one frame of your screen.")
                .setSmallIcon(android.R.drawable.ic_menu_camera)
                .setOngoing(true)
                .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }
}

/** The deadline a single frame is given before the capture gives up. */
private const val FRAME_TIMEOUT_MS = 6000L
