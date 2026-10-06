package dev.nexus.nexus

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Keeps the mesh alive while Nexus is in the background.
 *
 * The mesh is meant to be always-on: another Nexus device must be able to
 * reach this one — and a transfer it started must be able to land here — even
 * with the window closed. Android only grants an app that much background
 * life to a foreground service, and since Android 14 such a service must
 * declare *why* it is running. This one is a `dataSync` job: an ongoing
 * transfer/replication loop over the mesh rather than a one-off task.
 *
 * The service also owns the Wi-Fi multicast lock. Held by the activity it died
 * with the activity, so backgrounded discovery went deaf the moment the user
 * left the app; held here it lives exactly as long as the mesh does. The Dart
 * side starts and stops the service from `MeshService.start()/stop()` over the
 * existing `dev.nexus.nexus/network` channel (see `lib/mesh/sync_service.dart`).
 *
 * The service stops itself when Dart asks it to. It is deliberately NOT
 * sticky: if the process is killed the Flutter engine — and the mesh sockets
 * it owns — are gone too, so restarting an empty service would only show a
 * "connected" notification over a mesh that no longer exists.
 */
class NexusSyncService : Service() {
    companion object {
        private const val TAG = "NexusSync"
        private const val CHANNEL_ID = "nexus-sync"
        private const val NOTIFICATION_ID = 51820

        /** True while the service is running (and the multicast lock held). */
        @Volatile
        var running: Boolean = false
            private set

        /**
         * Asks Android to run the mesh inside a foreground service. A platform
         * that refuses a background start (Android 12+ restrictions) logs the
         * refusal rather than crashing — the mesh still runs while visible.
         */
        fun start(context: Context) {
            try {
                ContextCompat.startForegroundService(
                    context,
                    Intent(context, NexusSyncService::class.java),
                )
            } catch (e: Exception) {
                Log.w(TAG, "foreground service start refused: ${e.message}")
            }
        }

        /** Stops the service, releasing the multicast lock with it. */
        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, NexusSyncService::class.java))
            } catch (e: Exception) {
                Log.w(TAG, "foreground service stop failed: ${e.message}")
            }
        }
    }

    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // The notification must exist within a few seconds of the start call,
        // or the platform kills the process — post it before anything else.
        startInForeground()
        acquireMulticastLock()
        running = true
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseMulticastLock()
        running = false
        super.onDestroy()
    }

    /** Posts the ongoing notification and promotes the service to foreground. */
    private fun startInForeground() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Background sync",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Keeps Nexus reachable and transfers running."
                    setShowBadge(false)
                },
            )
        }
        val notification: Notification =
            Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("Nexus is connected")
                .setContentText("Reachable to your paired devices.")
                .setSmallIcon(android.R.drawable.stat_notify_sync)
                .setOngoing(true)
                .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Android 10+ lets the service say which type it runs as; since
            // Android 14 this must match the manifest's foregroundServiceType.
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /** Takes the Wi-Fi multicast lock once, for the life of the service. */
    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        try {
            val wifi = applicationContext.getSystemService(WifiManager::class.java)
            val lock = wifi.createMulticastLock("nexus-discovery")
            lock.setReferenceCounted(true)
            lock.acquire()
            multicastLock = lock
            Log.i(TAG, "multicast lock acquired — background discovery can receive")
        } catch (e: Exception) {
            Log.e(TAG, "multicast lock refused", e)
        }
    }

    private fun releaseMulticastLock() {
        try {
            if (multicastLock?.isHeld == true) multicastLock?.release()
        } catch (e: Exception) {
            Log.w(TAG, "multicast lock release failed: ${e.message}")
        }
        multicastLock = null
    }
}
