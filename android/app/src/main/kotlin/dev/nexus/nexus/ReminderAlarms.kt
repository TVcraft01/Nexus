package dev.nexus.nexus

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * The reminder's second half on Android: exact alarms plus the notification
 * they ring.
 *
 * Dart's engine timer only runs while the app is open. Every pending
 * reminder is therefore also handed here as an exact AlarmManager alarm, so
 * a reminder set at noon still rings at 6pm when Nexus spent the afternoon
 * closed. The alarm's receiver ([ReminderReceiver]) posts the notification
 * itself — by the time Dart runs again the moment has passed, and the
 * engine's startup check then only marks the reminder spent and says it in
 * the thread.
 *
 * Channel: `dev.nexus.nexus/reminders` (see `lib/core/reminder_alarms.dart`):
 * - `scheduleReminder {id, notificationId, text, triggerAtMillis}`
 * - `cancelReminder {id}` (notificationId re-derived the same way)
 * - `showReminderNotification {id, notificationId, text}`
 *
 * The notification id is computed in Dart and shared by the alarm post and
 * the in-app post, so an alarm firing while the app is open replaces the
 * notification instead of doubling it. Everything here is best-effort: a
 * denied exact-alarm permission falls back to an inexact window, and every
 * failure is a log line — the in-app timer is always the fallback.
 */
class ReminderAlarms(private val activity: MainActivity) {
    private val TAG = "NexusReminders"

    companion object {
        const val ACTION_REMIND = "dev.nexus.nexus.REMINDER_FIRED"
        const val CHANNEL_ID = "nexus-reminders"
    }

    fun registerChannels(method: MethodChannel) {
        method.setMethodCallHandler { call, result ->
            when (call.method) {
                "scheduleReminder" -> {
                    schedule(
                        notificationId = call.argument<Int>("notificationId") ?: 0,
                        text = call.argument<String>("text") ?: "",
                        triggerAtMillis = call.argument<Long>("triggerAtMillis")
                            ?: call.argument<Int>("triggerAtMillis")?.toLong()
                            ?: 0L,
                    )
                    result.success(null)
                }
                "cancelReminder" -> {
                    cancel(call.argument<Int>("notificationId") ?: 0)
                    result.success(null)
                }
                "showReminderNotification" -> {
                    ReminderReceiver.showNotification(
                        activity,
                        call.argument<Int>("notificationId") ?: 0,
                        call.argument<String>("text") ?: "",
                    )
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun schedule(notificationId: Int, text: String, triggerAtMillis: Long) {
        if (text.isEmpty() || triggerAtMillis <= 0L) return
        try {
            val manager =
                activity.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pending = alarmIntent(notificationId, text)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
                    !manager.canScheduleExactAlarms()
                ) {
                    // No exact-alarm permission: an inexact window still
                    // rings, just not to the minute.
                    manager.setAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        triggerAtMillis,
                        pending,
                    )
                } else {
                    manager.setExactAndAllowWhileIdle(
                        AlarmManager.RTC_WAKEUP,
                        triggerAtMillis,
                        pending,
                    )
                }
            } else {
                @Suppress("DEPRECATION")
                manager.setExact(
                    AlarmManager.RTC_WAKEUP,
                    triggerAtMillis,
                    pending,
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "schedule failed: ${e.message}")
        }
    }

    private fun cancel(notificationId: Int) {
        try {
            val manager =
                activity.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            manager.cancel(alarmIntent(notificationId, ""))
            ReminderReceiver.dismiss(activity, notificationId)
        } catch (e: Exception) {
            Log.w(TAG, "cancel failed: ${e.message}")
        }
    }

    private fun alarmIntent(notificationId: Int, text: String): PendingIntent {
        val intent = Intent(activity, ReminderReceiver::class.java).apply {
            action = ACTION_REMIND
            putExtra("notificationId", notificationId)
            putExtra("text", text)
        }
        return PendingIntent.getBroadcast(
            activity,
            notificationId,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}

/**
 * Fires when an exact reminder alarm goes off — including while the app is
 * closed — and posts the notification. The Dart engine marks the reminder
 * spent on its next run; this side never touches the store.
 */
class ReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ReminderAlarms.ACTION_REMIND) return
        val text = intent.getStringExtra("text").orEmpty()
        if (text.isEmpty()) return
        showNotification(context, intent.getIntExtra("notificationId", 0), text)
    }

    companion object {
        private const val TAG = "NexusReminders"

        fun showNotification(context: Context, notificationId: Int, text: String) {
            if (text.isEmpty()) return
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val manager =
                        context.getSystemService(NotificationManager::class.java)
                    manager.createNotificationChannel(
                        NotificationChannel(
                            ReminderAlarms.CHANNEL_ID,
                            "Reminders",
                            NotificationManager.IMPORTANCE_HIGH,
                        ).apply {
                            description = "Reminders you asked Nexus to ring."
                        },
                    )
                }
                val open = PendingIntent.getActivity(
                    context,
                    notificationId,
                    Intent(context, MainActivity::class.java).apply {
                        flags =
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP
                    },
                    PendingIntent.FLAG_UPDATE_CURRENT or
                        PendingIntent.FLAG_IMMUTABLE,
                )
                val notification: Notification =
                    Notification.Builder(context, ReminderAlarms.CHANNEL_ID)
                        .setContentTitle("Reminder")
                        .setContentText(text)
                        .setSmallIcon(android.R.drawable.ic_popup_reminder)
                        .setContentIntent(open)
                        .setAutoCancel(true)
                        .build()
                val manager =
                    context.getSystemService(Context.NOTIFICATION_SERVICE) as
                        NotificationManager
                manager.notify(notificationId, notification)
            } catch (e: Exception) {
                Log.w(TAG, "notify failed: ${e.message}")
            }
        }

        fun dismiss(context: Context, notificationId: Int) {
            try {
                val manager =
                    context.getSystemService(Context.NOTIFICATION_SERVICE) as
                        NotificationManager
                manager.cancel(notificationId)
            } catch (e: Exception) {
                Log.w(TAG, "dismiss failed: ${e.message}")
            }
        }
    }
}
