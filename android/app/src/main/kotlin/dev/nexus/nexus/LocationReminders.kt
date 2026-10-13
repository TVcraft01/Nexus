package dev.nexus.nexus

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.location.LocationManager
import android.os.Build
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * Place reminders on Android: the fence behind \"remind me at the store\".
 *
 * Dart resolves the name once (OpenStreetMap) and hands the coordinates
 * here; every pending fence is armed as a [LocationManager] proximity
 * alert, so arriving fires even when Nexus spent the afternoon closed.
 * The fence's receiver ([LocationFenceReceiver]) posts the notification
 * itself — reusing the nexus-reminders channel — and records the id; Dart
 * collects the fired ids on its next run, marks them spent in the store,
 * and says them in the thread. This side never touches the store.
 *
 * Why LocationManager and not GeofencingClient: the fencing client needs
 * Play Services on the device AND the play-services-location dependency to
 * compile against — neither verifiable in this headless pass. Proximity
 * alerts are framework-built-in, need no new dependency, and fire on the
 * same ENTER transition. If a Play-Services fence ever replaces this, the
 * channel contract below stays the same and only this file changes.
 *
 * Channel: `dev.nexus.nexus/location` (see `lib/core/location_reminders.dart`):
 * - `requestReminderLocation` → {ok, permanentlyDenied} (answered by the
 *   activity, which owns the permission dialog)
 * - `openAppSettings` → opens this app's system page (same owner)
 * - `currentLocation` → {ok, lat, lon} or null — the last-known fix, never
 *   a permission ask; null biases nothing and fails nothing
 * - `syncLocationGeofences {fences: [{id, notificationId, lat, lng,
 *   radiusM, what, placeName}]}` — arms every fence, replacing same-id ones
 * - `removeLocationGeofences {ids}` — drops fences whose reminders are
 *   gone or spent
 * - `takeFiredLocationIds` → [id, …], clearing the recorded set — each
 *   fire is collected exactly once
 *
 * Everything here is best-effort: a missing permission or provider is a
 * log line, and the stored reminder simply waits — unfired, never lost.
 */
class LocationReminders(private val activity: MainActivity) {
    private val TAG = "NexusLocation"

    companion object {
        const val ACTION_FENCE = "dev.nexus.nexus.LOCATION_FENCE"
        const val PREFS = "nexus_location_reminders"
        const val KEY_FIRED = "fired_ids"

        /// The fence's notification id: Dart computes the same value (see
        /// LocationGeofences.notificationId) so both sides agree — but the
        /// intent carries it anyway, so a fence armed by an older build
        /// still posts under a stable id.
        fun fenceNotificationId(
            fence: Map<String, Any?>,
            id: String,
        ): Int = (fence["notificationId"] as? Number)?.toInt()
            ?: stableId(id)

        /// DJB2 over UTF-16 units, masked to 31 bits — the same arithmetic
        /// as Dart's LocationGeofences.notificationId, so both sides derive
        /// the same id for the same reminder string. Long arithmetic on
        /// purpose: Kotlin Ints wrap on overflow while Dart's 64-bit ints
        /// do not, so masking a wrapped value would answer differently.
        /// Stability matters because the platform matches fences by the
        /// request code below: a re-seeded id orphans yesterday's fence.
        fun stableId(id: String): Int {
            var hash = 5381L
            for (c in id) {
                hash = ((hash shl 5) + hash + c.code) and 0x7fffffffL
            }
            return hash.toInt()
        }

        fun recordFired(context: Context, id: String) {
            if (id.isEmpty()) return
            try {
                val prefs = context.getSharedPreferences(
                    PREFS,
                    Context.MODE_PRIVATE,
                )
                val next = prefs.getStringSet(KEY_FIRED, emptySet())
                    .orEmpty().toMutableSet()
                next.add(id)
                prefs.edit().putStringSet(KEY_FIRED, next).apply()
            } catch (e: Exception) {
                Log.w("NexusLocation", "record fired failed: ${e.message}")
            }
        }
    }

    fun registerChannels(method: MethodChannel) {
        method.setMethodCallHandler { call, result ->
            when (call.method) {
                "requestReminderLocation" ->
                    activity.requestReminderLocation(result)
                "openAppSettings" -> {
                    activity.openAppSettings()
                    result.success(null)
                }
                "currentLocation" -> currentFix(result)
                "syncLocationGeofences" -> {
                    @Suppress("UNCHECKED_CAST")
                    sync(call.argument<List<Map<String, Any?>>>("fences"))
                    result.success(null)
                }
                "removeLocationGeofences" -> {
                    @Suppress("UNCHECKED_CAST")
                    remove(call.argument<List<String>>("ids"))
                    result.success(null)
                }
                "takeFiredLocationIds" -> result.success(takeFired())
                else -> result.notImplemented()
            }
        }
    }

    /// The current fix for biasing a map lookup: the freshest last-known
    /// fix across providers, or null. Never asks for anything — no
    /// permission, no dialog, no wait. Null only un-biases the match.
    private fun currentFix(result: MethodChannel.Result) {
        try {
            val lm = activity.getSystemService(LocationManager::class.java)
            val fix = listOf(
                LocationManager.NETWORK_PROVIDER,
                LocationManager.GPS_PROVIDER,
            ).firstNotNullOfOrNull { provider ->
                try {
                    lm.getLastKnownLocation(provider)
                } catch (e: SecurityException) {
                    null
                }
            }
            result.success(
                if (fix != null) {
                    mapOf(
                        "ok" to true,
                        "lat" to fix.latitude,
                        "lon" to fix.longitude,
                    )
                } else {
                    null
                },
            )
        } catch (e: Exception) {
            Log.w(TAG, "current fix failed: ${e.message}")
            result.success(null)
        }
    }

    private fun sync(fences: List<Map<String, Any?>>?) {
        if (fences == null) return
        val manager = try {
            activity.getSystemService(LocationManager::class.java)
        } catch (e: Exception) {
            Log.w(TAG, "no location manager: ${e.message}")
            return
        }
        for (fence in fences) {
            try {
                val lat = (fence["lat"] as? Number)?.toDouble() ?: continue
                val lng = (fence["lon"] as? Number)?.toDouble()
                    ?: (fence["lng"] as? Number)?.toDouble()
                    ?: continue
                val radius = (fence["radiusM"] as? Number)?.toFloat()
                    ?: 200f
                manager.addProximityAlert(
                    lat,
                    lng,
                    radius,
                    -1, // never expire: the store's spent mark retires fences
                    fenceIntent(fence),
                )
            } catch (e: SecurityException) {
                Log.w(TAG, "fence needs permission: ${e.message}")
            } catch (e: Exception) {
                Log.w(TAG, "fence failed: ${e.message}")
            }
        }
    }

    private fun remove(ids: List<String>?) {
        if (ids.isNullOrEmpty()) return
        val manager = try {
            activity.getSystemService(LocationManager::class.java)
        } catch (e: Exception) {
            return
        }
        for (id in ids) {
            try {
                manager.removeProximityAlert(fenceIntent(mapOf("id" to id)))
            } catch (e: Exception) {
                Log.w(TAG, "unfence failed: ${e.message}")
            }
        }
    }

    private fun fenceIntent(fence: Map<String, Any?>): PendingIntent {
        val id = fence["id"]?.toString().orEmpty()
        val intent = Intent(activity, LocationFenceReceiver::class.java).apply {
            action = ACTION_FENCE
            putExtra("id", id)
            putExtra("what", fence["what"]?.toString().orEmpty())
            putExtra("placeName", fence["placeName"]?.toString().orEmpty())
            putExtra("notificationId", fenceNotificationId(fence, id))
        }
        // Mutable on purpose: the system fills in KEY_PROXIMITY_ENTERING
        // on delivery, which an immutable intent rejects — the fence then
        // never arms ("pending intent must be mutable"). FLAG_MUTABLE
        // exists only from Android 12; below that intents are mutable by
        // default. (The exact-alarm intents stay immutable: nothing writes
        // into those.)
        val flags =
            PendingIntent.FLAG_UPDATE_CURRENT or
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                PendingIntent.FLAG_MUTABLE
            } else {
                0
            }
        return PendingIntent.getBroadcast(
            activity,
            stableId(id),
            intent,
            flags,
        )
    }

    private fun takeFired(): List<String> {
        val prefs = try {
            activity.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        } catch (e: Exception) {
            return emptyList()
        }
        val fired = prefs.getStringSet(KEY_FIRED, emptySet()).orEmpty().toList()
        if (fired.isNotEmpty()) {
            prefs.edit().remove(KEY_FIRED).apply()
        }
        return fired
    }
}

/**
 * Fires when a place fence is entered — including while the app is
 * closed — posts the notification on the shared nexus-reminders channel,
 * and records the id for Dart to collect. Exits (dwelling, leaving)
 * are silence: a reminder fires on arrival, never on departure.
 */
class LocationFenceReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != LocationReminders.ACTION_FENCE) return
        val entering = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            intent.getBooleanExtra(LocationManager.KEY_PROXIMITY_ENTERING, true)
        } else {
            @Suppress("DEPRECATION")
            intent.getBooleanExtra(LocationManager.KEY_PROXIMITY_ENTERING, true)
        }
        if (!entering) return
        val id = intent.getStringExtra("id").orEmpty()
        if (id.isEmpty()) return
        val what = intent.getStringExtra("what").orEmpty()
        val place = intent.getStringExtra("placeName").orEmpty()
        val text = if (what.isEmpty()) {
            "You arrived${if (place.isEmpty()) "" else " at $place"}."
        } else {
            "$what — you arrived${if (place.isEmpty()) "" else " at $place"}."
        }
        ReminderReceiver.showNotification(
            context,
            intent.getIntExtra("notificationId", id.hashCode() and 0x7fffffff),
            text,
        )
        LocationReminders.recordFired(context, id)
    }
}
