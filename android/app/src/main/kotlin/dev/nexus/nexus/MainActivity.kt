package dev.nexus.nexus

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Environment
import android.provider.ContactsContract
import android.provider.Settings
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "dev.nexus.nexus/installer"
    private val TAG = "NexusInstaller"
    private val REQUEST_INSTALL_PERMISSION = 42601

    // The APK we were about to install when the unknown-sources permission
    // was missing. The install resumes as soon as the user grants it and
    // returns from the system settings screen.
    private var pendingInstallPath: String? = null

    private val STORAGE_CHANNEL = "dev.nexus.nexus/storage"
    private val PHONE_CHANNEL = "dev.nexus.nexus/phone"
    private val DEVICE_CHANNEL = "dev.nexus.nexus/device"

    // "call mom" from the assistant: resolving a contact needs READ_CONTACTS
    // and placing the call needs CALL_PHONE — both requested at runtime on
    // first use, holding the MethodChannel result across the dialogs so the
    // reply reflects what actually happened.
    private val REQUEST_CALL_PERMISSIONS = 42602
    private var pendingCallName: String? = null
    private var pendingCallResult: MethodChannel.Result? = null
    private var pendingCallRequested: List<String> = emptyList()

    private lateinit var usbSerial: UsbSerialBridge

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "installApk") {
                    val path = call.argument<String>("path")
                    if (path != null) {
                        result.success(installApk(path))
                    } else {
                        result.error("NO_PATH", "No APK path provided", null)
                    }
                } else {
                    result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "allFilesAccess" -> result.success(hasAllFilesAccess())
                    "openAllFilesAccessSettings" -> {
                        openAllFilesAccessSettings()
                        result.success(true)
                    }
                    "sharedRoot" -> result.success(
                        Environment.getExternalStorageDirectory().absolutePath
                    )
                    else -> result.notImplemented()
                }
            }

        // "call mom" from the assistant: resolve the contact and place the
        // call directly (ACTION_CALL), falling back to the prefilled dialer
        // when CALL_PHONE is unavailable.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PHONE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "callContact" -> callContact(call.argument<String>("name") ?: "", result)
                    else -> result.notImplemented()
                }
            }

        // Small device-local actions: alarms, timers, search, navigation,
        // torch, battery, volume. All fire-and-report — no runtime
        // permissions needed beyond the normal SET_ALARM.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                result.success(runDeviceAction(call.method, call.arguments))
            }

        // USB-OTG serial: microcontrollers (ESP32, …) plugged into the phone.
        usbSerial = UsbSerialBridge(this)
        usbSerial.registerChannels(
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                "dev.nexus.nexus/usb_serial",
            ),
            EventChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                "dev.nexus.nexus/usb_serial_events",
            ),
        )
    }

    /// Whether the app may read the whole shared storage. On Android 11+ that
    /// is the "All files access" toggle (MANAGE_EXTERNAL_STORAGE); on older
    /// versions the READ_EXTERNAL_STORAGE runtime permission suffices.
    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        }
    }

    /// Opens the system screen where the user flips the "All files access"
    /// toggle for this app (Android 11+), or the app details page otherwise.
    private fun openAllFilesAccessSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:$packageName")
            )
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.parse("package:$packageName"))
        }
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    /// Returns "launched" (installer open), "permission" (routed the user to
    /// the system unknown-sources screen; the install will continue when they
    /// grant it), or "error".
    private fun installApk(path: String): String {
        val source = File(path)
        if (!source.exists()) {
            Log.e(TAG, "APK not found at $path")
            return "error"
        }

        // Android 8+ refuses to install without the "install unknown apps"
        // permission — the session dies instantly with
        // INSTALL_FAILED_VERIFICATION_FAILURE. Open the system settings
        // screen for this app first; the install resumes on return.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
            pendingInstallPath = path
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName")
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivityForResult(intent, REQUEST_INSTALL_PERMISSION)
            Log.i(TAG, "unknown-sources permission missing — opening settings")
            return "permission"
        }
        return if (launchInstaller(path)) "launched" else "error"
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_CALL_PERMISSIONS) {
            val name = pendingCallName
            val result = pendingCallResult
            pendingCallName = null
            pendingCallResult = null
            if (result == null) return
            val granted = { perm: String ->
                permissions.indexOf(perm).let { it >= 0 && grantResults[it] == PackageManager.PERMISSION_GRANTED }
            }
            if (!granted(Manifest.permission.READ_CONTACTS)) {
                result.success(mapOf("placed" to false, "launched" to false, "candidates" to emptyList<String>(),
                    "message" to "Contacts permission was not granted."))
                return
            }
            val (number, ranked) = lookupContacts(name ?: "")
            if (number == null) {
                result.success(noContactResult(name ?: "", ranked))
                return
            }
            result.success(
                if (granted(Manifest.permission.CALL_PHONE)) placeCall(name ?: "", number)
                else openDialer(name ?: "", number)
            )
        }
    }

    /// Runs a device-local action and returns {ok, message}. Everything is
    /// an intent or a public API — nothing here needs a runtime permission.
    private fun runDeviceAction(method: String, arguments: Any?): Map<String, Any?> {
        val args = arguments as? Map<*, *>
        return try {
            when (method) {
                "setAlarm" -> setAlarm(
                    (args?.get("hour") as Number).toInt(),
                    (args["minute"] as Number).toInt(),
                )
                "setTimer" -> setTimer((args?.get("seconds") as Number).toInt())
                "webSearch" -> startActionIntent(
                    Intent(Intent.ACTION_WEB_SEARCH).apply {
                        putExtra("query", args?.get("query")?.toString() ?: "")
                    },
                    "searched the web",
                )
                "navigateTo" -> startActionIntent(
                    Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=" +
                        Uri.encode(args?.get("place")?.toString() ?: ""))),
                    "opened directions",
                )
                "torch" -> setTorch(args?.get("mode")?.toString() != "off")
                "battery" -> batteryStatus()
                "volume" -> adjustVolume(args?.get("mode")?.toString() ?: "up")
                else -> mapOf("ok" to false, "message" to "Not available on this device.")
            }
        } catch (e: Exception) {
            Log.e(TAG, "$method failed", e)
            mapOf("ok" to false, "message" to "That didn't work: ${e.message ?: method}")
        }
    }

    private fun setAlarm(hour: Int, minute: Int): Map<String, Any?> {
        val intent = Intent(android.provider.AlarmClock.ACTION_SET_ALARM).apply {
            putExtra(android.provider.AlarmClock.EXTRA_HOUR, hour)
            putExtra(android.provider.AlarmClock.EXTRA_MINUTES, minute)
            putExtra(android.provider.AlarmClock.EXTRA_SKIP_UI, true)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
        return mapOf("ok" to true, "message" to "Alarm set for %02d:%02d.".format(hour, minute))
    }

    private fun setTimer(seconds: Int): Map<String, Any?> {
        val intent = Intent(android.provider.AlarmClock.ACTION_SET_TIMER).apply {
            putExtra(android.provider.AlarmClock.EXTRA_LENGTH, seconds)
            putExtra(android.provider.AlarmClock.EXTRA_SKIP_UI, true)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
        val m = seconds / 60
        val s = seconds % 60
        val pretty = if (m > 0) "$m min${if (s > 0) " $s s" else ""}" else "$s s"
        return mapOf("ok" to true, "message" to "Timer running for $pretty.")
    }

    private fun startActionIntent(intent: Intent, done: String): Map<String, Any?> {
        startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        return mapOf("ok" to true, "message" to done.replaceFirstChar { it.uppercase() } + ".")
    }

    private fun setTorch(on: Boolean): Map<String, Any?> {
        val cm = getSystemService(CameraManager::class.java)
        val back = cm.cameraIdList.firstOrNull { id ->
            cm.getCameraCharacteristics(id).get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_BACK
        } ?: throw IllegalStateException("no flashlight on this phone")
        cm.setTorchMode(back, on)
        return mapOf("ok" to true, "message" to if (on) "Flashlight on." else "Flashlight off.")
    }

    private fun batteryStatus(): Map<String, Any?> {
        val bm = getSystemService(BatteryManager::class.java)
        val level = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        val sticky = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val status = sticky?.getIntExtra(BatteryManager.EXTRA_STATUS, -1) ?: -1
        val charging = status == BatteryManager.BATTERY_STATUS_CHARGING ||
            status == BatteryManager.BATTERY_STATUS_FULL
        val plugged = sticky?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        val source = when {
            plugged == BatteryManager.BATTERY_PLUGGED_USB -> " (on USB)"
            plugged == BatteryManager.BATTERY_PLUGGED_AC -> " (charging)"
            plugged != 0 -> " (charging)"
            else -> ""
        }
        return mapOf(
            "ok" to true,
            "message" to "Battery at $level%${if (charging) "$source — charging" else ""}.",
            "level" to level,
            "charging" to charging,
        )
    }

    private fun adjustVolume(mode: String): Map<String, Any?> {
        val am = getSystemService(AudioManager::class.java)
        when (mode) {
            "mute" -> am.adjustStreamVolume(
                AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, 0)
            "down" -> am.adjustStreamVolume(
                AudioManager.STREAM_MUSIC, AudioManager.ADJUST_LOWER, 0)
            else -> am.adjustStreamVolume(
                AudioManager.STREAM_MUSIC, AudioManager.ADJUST_RAISE, 0)
        }
        return mapOf("ok" to true, "message" to "Volume $mode.")
    }

    /// Resolves a contact name and places the call directly (ACTION_CALL).
    /// Missing permissions are requested at runtime on first use; without
    /// CALL_PHONE it falls back to the prefilled dialer. When nothing
    /// matches, the closest contact names travel back so the assistant can
    /// ask "who did you mean?".
    private fun callContact(name: String, result: MethodChannel.Result) {
        val contact = name.trim()
        if (contact.isEmpty()) {
            result.success(mapOf("placed" to false, "launched" to false, "candidates" to emptyList<String>(),
                "message" to "No contact name given."))
            return
        }
        val missing = listOf(Manifest.permission.READ_CONTACTS, Manifest.permission.CALL_PHONE)
            .filter { checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isNotEmpty()) {
            pendingCallName = contact
            pendingCallResult = result
            pendingCallRequested = missing
            requestPermissions(missing.toTypedArray(), REQUEST_CALL_PERMISSIONS)
            return
        }
        val (number, ranked) = lookupContacts(contact)
        result.success(
            when {
                number == null -> noContactResult(contact, ranked)
                else -> placeCall(contact, number)
            }
        )
    }

    private fun noContactResult(name: String, ranked: List<String>): Map<String, Any?> = mapOf(
        "placed" to false,
        "launched" to false,
        "candidates" to ranked,
        "message" to "No contact named \"$name\" on this device."
    )

    /// Starts the call itself — zero taps after the message is sent.
    private fun placeCall(name: String, number: String): Map<String, Any?> = try {
        val intent = Intent(Intent.ACTION_CALL, Uri.fromParts("tel", number, null)).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
        Log.i(TAG, "calling $name ($number)")
        mapOf("placed" to true, "launched" to false, "candidates" to emptyList<String>(),
            "number" to number, "message" to "Calling $name ($number).")
    } catch (e: Exception) {
        Log.e(TAG, "direct call failed — falling back to the dialer", e)
        openDialer(name, number)
    }

    /// Fallback: opens the system dialer with the number prefilled.
    private fun openDialer(name: String, number: String): Map<String, Any?> = try {
        val intent = Intent(Intent.ACTION_DIAL, Uri.fromParts("tel", number, null)).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(intent)
        Log.i(TAG, "opened dialer for $name ($number)")
        mapOf("placed" to false, "launched" to true, "candidates" to emptyList<String>(),
            "number" to number, "message" to "Opened the dialer for $name ($number) — press call.")
    } catch (e: Exception) {
        Log.e(TAG, "could not open the dialer", e)
        mapOf("placed" to false, "launched" to false, "candidates" to emptyList<String>(),
            "message" to "Could not open the dialer.")
    }

    /// Best number for [name] plus the closest matching display names.
    /// Only an exact or case-insensitive-full name match is trusted enough
    /// to dial immediately; looser matches come back as candidates so the
    /// assistant can ask "who did you mean?" and learn the wording.
    private fun lookupContacts(name: String): Pair<String?, List<String>> {
        return try {
            val uri = ContactsContract.CommonDataKinds.Phone.CONTENT_URI
            val projection = arrayOf(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
            )
            contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                // First number wins per display name.
                val numberByName = LinkedHashMap<String, String>()
                while (cursor.moveToNext()) {
                    val displayName = cursor.getString(0) ?: continue
                    numberByName.putIfAbsent(displayName, cursor.getString(1))
                }
                val names = numberByName.keys.toList()
                val q = name.trim()
                val lower = contactMatchKey(q)
                val confident = names.any { contactMatchKey(it) == lower }
                val ranked = rankedContactMatches(names, name)
                Pair(
                    if (confident) ranked.firstOrNull()?.let { numberByName[it] } else null,
                    ranked,
                )
            } ?: Pair(null, emptyList())
        } catch (e: Exception) {
            Log.e(TAG, "contact lookup failed", e)
            Pair(null, emptyList())
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_INSTALL_PERMISSION) {
            val path = pendingInstallPath
            pendingInstallPath = null
            val granted = Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                packageManager.canRequestPackageInstalls()
            if (path != null && granted) {
                Log.i(TAG, "permission granted — resuming install")
                launchInstaller(path)
            }
        }
    }

    private fun launchInstaller(path: String): Boolean {
        return try {
            val source = File(path)
            if (!source.exists()) {
                Log.e(TAG, "APK not found at $path")
                return false
            }

            // Copy into cacheDir so the file lives under the directory the
            // FileProvider declares as its cache-path root. The downloaded
            // APK lives in code_cache, whose canonical path (e.g.
            // /data/data/...) can differ from getCodeCacheDir()'s canonical
            // path (/data/user/0/...) on some devices, which makes
            // FileProvider's startsWith check fail.
            val target = File(cacheDir, "nexus-update.apk")
            source.copyTo(target, overwrite = true)
            Log.i(TAG, "copied $path -> ${target.canonicalPath} (${target.length()} bytes)")

            val uri: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                FileProvider.getUriForFile(
                    this,
                    "${applicationContext.packageName}.updater",
                    target
                )
            } else {
                Uri.fromFile(target)
            }

            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            Log.e(TAG, "launchInstaller failed", e)
            false
        }
    }
}

/// Picks the contact display name that best matches [query]:
/// 1. exact, 2. case-insensitive full, 3. prefix, 4. contains; null when
/// nothing matches. Pure so it is unit-testable without a contacts provider.
fun pickBestContactMatch(candidates: List<String>, query: String): String? =
    rankedContactMatches(candidates, query, limit = 1).firstOrNull()

/// Lowercased with diacritics folded ("café" -> "cafe") so typed queries
/// without accents still match real contact names.
fun contactMatchKey(s: String): String {
    val folded = java.text.Normalizer.normalize(s.trim(), java.text.Normalizer.Form.NFD)
    return folded.replace(Regex("\\p{Mn}+"), "").lowercase()
}

/// The closest matches for [query], best first (same tiers as above),
/// deduplicated and capped at [limit] — what the assistant offers when the
/// best guess is wrong or missing.
fun rankedContactMatches(candidates: List<String>, query: String, limit: Int = 3): List<String> {
    val q = query.trim()
    if (q.isEmpty() || limit <= 0) return emptyList()
    val lower = contactMatchKey(q)
    return sequenceOf(
        candidates.asSequence().filter { it == q },
        candidates.asSequence().filter { it.lowercase() == lower },
        candidates.asSequence().filter { contactMatchKey(it) == lower },
        candidates.asSequence().filter { contactMatchKey(it).startsWith(lower) },
        candidates.asSequence().filter { contactMatchKey(it).contains(lower) },
    )
        .flatten()
        .distinct()
        .take(limit)
        .toList()
}
