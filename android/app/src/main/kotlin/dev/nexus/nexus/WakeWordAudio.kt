package dev.nexus.nexus

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Build
import android.os.Process
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel

/// The wake word's microphone: a small AudioRecord thread pushing 16 kHz
/// mono PCM chunks to Dart, where the openWakeWord ONNX engine scores them
/// on the phone.
///
/// Why here and not in the activity: the activity owns the Dart engine (the
/// EventChannel sink dies with it), but the loop itself is a plain object so
/// NexusSyncService — the mesh's foreground service, already keeping the
/// process alive — can own its lifetime. Today that means: the loop starts
/// when the Settings toggle is on AND the assistant screen is open (Dart
/// calls start/stop), and it always dies with the service in onDestroy. If
/// the app is swiped away the sink breaks and the loop stops itself, so
/// there is no headless mic running with nobody scoring — that would burn
/// battery for nothing. True always-on (killed-app) detection is a later
/// pass: it needs the ONNX engine moved into the service process, not just
/// this thread.
///
/// Privacy: chunks are pushed to Dart and dropped after scoring. Nothing is
/// written to disk, nothing leaves the phone — a detection is the only thing
/// that ever comes out of this, as an event.
object WakeWordAudio {
    const val ACTION_SILENCE = "dev.nexus.nexus.WAKE_SILENCE"
    const val CHANNEL_ID = "nexus-wake"
    private const val TAG = "NexusWake"
    private const val SAMPLE_RATE = 16000

    /// 80 ms at 16 kHz mono — the chunk size the openWakeWord engine eats.
    private const val CHUNK_SHORTS = 1280

    private const val NOTIFICATION_ID = 42071

    @Volatile private var worker: Thread? = null
    @Volatile private var recorder: AudioRecord? = null

    val running: Boolean get() = worker != null

    /// Starts the loop. False when the mic is unavailable (permission denied
    /// elsewhere, no recorder, hardware busy) — Dart keeps the toggle off.
    /// Idempotent: an already-running loop answers true without reopening
    /// the microphone.
    fun start(context: Context, sink: EventChannel.EventSink?): Boolean {
        if (running) return true
        val app = context.applicationContext
        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBuf <= 0) {
            Log.e(TAG, "wake: no microphone buffer (error $minBuf)")
            return false
        }
        val rec = try {
            AudioRecord(
                MediaRecorder.AudioSource.MIC,
                SAMPLE_RATE,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                minBuf * 2,
            )
        } catch (e: Exception) {
            Log.e(TAG, "wake: cannot open the microphone", e)
            return false
        }
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            Log.e(TAG, "wake: recorder not initialized (state ${rec.state})")
            runCatching { rec.release() }
            return false
        }
        try {
            rec.startRecording()
        } catch (e: Exception) {
            Log.e(TAG, "wake: startRecording refused", e)
            runCatching { rec.release() }
            return false
        }
        recorder = rec
        ensureChannel(app)
        postListening(app)
        val t = Thread({ loop(rec, sink, app) }, "nexus-wake-audio")
        t.isDaemon = true
        worker = t
        t.start()
        Log.i(TAG, "wake: audio loop running, listening for the wake word")
        return true
    }

    /// Stops the loop and releases the microphone. Safe to call when idle.
    fun stop(context: Context) {
        worker = null
        val rec = recorder
        recorder = null
        rec?.let {
            runCatching { it.stop() }
            runCatching { it.release() }
        }
        runCatching {
            val nm = context.applicationContext
                .getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.cancel(NOTIFICATION_ID)
        }
        Log.i(TAG, "wake: audio loop stopped")
    }

    private fun loop(
        rec: AudioRecord,
        sink: EventChannel.EventSink?,
        app: Context,
    ) {
        Process.setThreadPriority(Process.THREAD_PRIORITY_AUDIO)
        val shorts = ShortArray(CHUNK_SHORTS)
        val bytes = ByteArray(CHUNK_SHORTS * 2)
        try {
            while (worker === Thread.currentThread()) {
                val n = try {
                    rec.read(shorts, 0, shorts.size)
                } catch (e: Exception) {
                    Log.w(TAG, "wake: mic read failed, stopping", e)
                    break
                }
                if (n < 0) {
                    Log.w(TAG, "wake: mic read error $n, stopping")
                    break
                }
                if (n == 0) continue
                // Little-endian pack: Dart rebuilds Int16List the same way.
                for (i in 0 until n) {
                    val s = shorts[i].toInt()
                    bytes[i * 2] = (s and 0xFF).toByte()
                    bytes[i * 2 + 1] = ((s shr 8) and 0xFF).toByte()
                }
                try {
                    sink?.success(bytes.copyOf(n * 2))
                } catch (e: Exception) {
                    // The activity (and its Dart engine) is gone — scoring
                    // stopped, so capturing must stop too.
                    Log.i(TAG, "wake: sink gone, stopping the loop")
                    break
                }
            }
        } finally {
            // Whoever stopped us (stop(), the service dying, a dead sink)
            // funnels here: the mic is released exactly once.
            if (worker === Thread.currentThread()) worker = null
            if (recorder === rec) recorder = null
            runCatching { rec.stop() }
            runCatching { rec.release() }
            runCatching {
                val nm = app.getSystemService(Context.NOTIFICATION_SERVICE)
                    as NotificationManager
                nm.cancel(NOTIFICATION_ID)
            }
            Log.i(TAG, "wake: loop ended, microphone released")
        }
    }

    private fun ensureChannel(app: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = app.getSystemService(Context.NOTIFICATION_SERVICE)
            as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        nm.createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Wake word",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = "Shown while Nexus listens for the wake word"
            },
        )
    }

    /// The persistent notice: while the mic is open the user must see it.
    /// Tapping it opens Nexus; "Stop listening" kills the loop at once.
    private fun postListening(app: Context) {
        val openApp = PendingIntent.getActivity(
            app,
            0,
            app.packageManager.getLaunchIntentForPackage(app.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val silence = PendingIntent.getBroadcast(
            app,
            1,
            Intent(app, WakeWordSilenceReceiver::class.java)
                .setAction(ACTION_SILENCE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val note = NotificationCompat.Builder(app, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("Nexus is listening for “Hey Jarvis”")
            .setContentText("Audio stays on this phone. Tap Stop to silence.")
            .setContentIntent(openApp)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Stop listening",
                silence,
            )
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
        val nm = app.getSystemService(Context.NOTIFICATION_SERVICE)
            as NotificationManager
        runCatching { nm.notify(NOTIFICATION_ID, note) }
    }

    /// Whether RECORD_AUDIO is currently granted. MainActivity asks when it
    /// is not; the loop never opens the mic without it.
    fun hasPermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
}

/// The notification's "Stop listening" button. Kills the audio loop and the
/// speech recognizer in flight, and answers the pending listen call with
/// nothing heard — one tap, total silence.
class WakeWordSilenceReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != WakeWordAudio.ACTION_SILENCE) return
        Log.i("NexusWake", "wake: silenced from the notification")
        WakeWordAudio.stop(context)
        MainActivity.silenceFromNotification()
    }
}
