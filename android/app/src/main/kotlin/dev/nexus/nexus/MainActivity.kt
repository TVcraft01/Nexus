package dev.nexus.nexus

import android.Manifest
import android.app.ActivityManager
import android.content.BroadcastReceiver
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.media.AudioManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import android.provider.ContactsContract
import android.provider.Settings
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.telephony.TelephonyManager
import android.util.Log
import android.view.KeyEvent
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
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

    // "text mom": resolving the recipient needs READ_CONTACTS too, requested
    // on first use with the MethodChannel result held across the dialog.
    private val REQUEST_TEXT_PERMISSIONS = 42603
    private var pendingTextContact: String? = null
    private var pendingTextBody: String? = null
    private var pendingTextResult: MethodChannel.Result? = null

    // "video call mom on whatsapp": same READ_CONTACTS flow as calls/texts.
    private val REQUEST_VIDEO_PERMISSIONS = 42604
    private var pendingVideoContact: String? = null
    private var pendingVideoApp: String? = null
    private var pendingVideoResult: MethodChannel.Result? = null

    // "email mom": resolving the address needs READ_CONTACTS too, requested
    // on first use with the MethodChannel result held across the dialog.
    private val REQUEST_EMAIL_PERMISSIONS = 42605
    private var pendingEmailContact: String? = null
    private var pendingEmailBody: String? = null
    private var pendingEmailResult: MethodChannel.Result? = null

    // "what is the weather": a one-time coarse location grant so the
    // forecast can be for where the phone is. The result is held across the
    // dialog; a declined grant answers honestly with null (IP fallback).
    private val REQUEST_LOCATION_PERMISSIONS = 42606
    private var pendingLocationResult: MethodChannel.Result? = null
    private val locationTimeout = Runnable {
        finishLocation(null)
    }

    // Voice input: RECORD_AUDIO is requested at runtime on first use, with
    // the MethodChannel result held across the dialog like the call flow.
    private val SPEECH_CHANNEL = "dev.nexus.nexus/speech"
    private val REQUEST_SPEECH_PERMISSIONS = 42605
    private var pendingSpeechResult: MethodChannel.Result? = null

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
                    "callContact" -> callContact(
                        call.argument<String>("name") ?: "",
                        call.argument<String>("number"),
                        result,
                    )
                    "videoCall" -> videoCall(
                        call.argument<String>("name") ?: "",
                        call.argument<String>("app"),
                        result,
                    )
                    else -> result.notImplemented()
                }
            }

        // Voice input: one utterance through the system SpeechRecognizer.
        // The recognized words come back as text and run through the same
        // assistant pipeline as typing.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SPEECH_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "listen") listenSpeech(result)
                else result.notImplemented()
            }

        // Small device-local actions: alarms, timers, search, navigation,
        // torch, battery, volume. All fire-and-report — no runtime
        // permissions needed beyond the normal SET_ALARM.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "sendText") {
                    // Texting resolves the recipient's number first, exactly
                    // like calls — which can ask for READ_CONTACTS, so it is
                    // handled asynchronously rather than fire-and-report.
                    val args = call.arguments as? Map<*, *>
                    sendText(
                        args?.get("contact")?.toString() ?: "",
                        args?.get("number")?.toString(),
                        args?.get("body")?.toString(),
                        result,
                    )
                } else if (call.method == "sendEmail") {
                    // Emailing resolves the recipient's address first, exactly
                    // like texts — same READ_CONTACTS flow.
                    val args = call.arguments as? Map<*, *>
                    sendEmail(
                        args?.get("contact")?.toString() ?: "",
                        args?.get("body")?.toString(),
                        result,
                    )
                } else if (call.method == "location") {
                    requestLocation(result)
                } else {
                    result.success(runDeviceAction(call.method, call.arguments))
                }
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
        val granted = { perm: String ->
            permissions.indexOf(perm).let { it >= 0 && grantResults[it] == PackageManager.PERMISSION_GRANTED }
        }
        if (requestCode == REQUEST_CALL_PERMISSIONS) {
            val name = pendingCallName
            val result = pendingCallResult
            pendingCallName = null
            pendingCallResult = null
            if (result == null) return
            if (!granted(Manifest.permission.READ_CONTACTS)) {
                result.success(mapOf("placed" to false, "launched" to false, "candidates" to emptyList<String>(),
                    "message" to "Contacts permission was not granted."))
                return
            }
            val (number, matched, ranked) = lookupContacts(name ?: "")
            if (number == null) {
                result.success(noContactResult(name ?: "", ranked, matched))
                return
            }
            result.success(
                if (granted(Manifest.permission.CALL_PHONE)) placeCall(name ?: "", number)
                else openDialer(name ?: "", number)
            )
        }
        if (requestCode == REQUEST_TEXT_PERMISSIONS) {
            val name = pendingTextContact
            val body = pendingTextBody
            val result = pendingTextResult
            pendingTextContact = null
            pendingTextBody = null
            pendingTextResult = null
            if (result == null) return
            if (!granted(Manifest.permission.READ_CONTACTS)) {
                result.success(mapOf(
                    "ok" to false,
                    "message" to "Contacts permission was not granted — I can't look up \"${name ?: ""}\".",
                ))
                return
            }
            finishText(name ?: "", body, result)
        }
        if (requestCode == REQUEST_VIDEO_PERMISSIONS) {
            val name = pendingVideoContact
            val app = pendingVideoApp
            val result = pendingVideoResult
            pendingVideoContact = null
            pendingVideoApp = null
            pendingVideoResult = null
            if (result == null) return
            if (!granted(Manifest.permission.READ_CONTACTS)) {
                result.success(mapOf(
                    "ok" to false,
                    "message" to "Contacts permission was not granted — I can't look up \"${name ?: ""}\".",
                ))
                return
            }
            finishVideo(name ?: "", app ?: "", result)
        }
        if (requestCode == REQUEST_EMAIL_PERMISSIONS) {
            val name = pendingEmailContact
            val body = pendingEmailBody
            val result = pendingEmailResult
            pendingEmailContact = null
            pendingEmailBody = null
            pendingEmailResult = null
            if (result == null) return
            if (!granted(Manifest.permission.READ_CONTACTS)) {
                result.success(mapOf(
                    "ok" to false,
                    "message" to "Contacts permission was not granted — I can't look up \"${name ?: ""}\".",
                ))
                return
            }
            finishEmail(name ?: "", body, result)
        }
        if (requestCode == REQUEST_LOCATION_PERMISSIONS) {
            val result = pendingLocationResult
            if (result == null) return
            if (granted(Manifest.permission.ACCESS_COARSE_LOCATION)) resolveLocation(result)
            else result.success(null) // honest: no location → IP fallback
        }
        if (requestCode == REQUEST_SPEECH_PERMISSIONS) {
            val result = pendingSpeechResult
            pendingSpeechResult = null
            if (result == null) return
            if (granted(Manifest.permission.RECORD_AUDIO)) startSpeech(result)
            else result.success(null) // honest: nothing was recognized
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
                "navigateTo" -> startActionIntentChooser(
                    Intent(Intent.ACTION_VIEW, Uri.parse("geo:0,0?q=" +
                        Uri.encode(args?.get("place")?.toString() ?: ""))),
                    "opened directions",
                    "Open with",
                )
                "calendarEvent" -> startActionIntentChooser(
                    Intent(Intent.ACTION_INSERT).apply {
                        data = CalendarContract.Events.CONTENT_URI
                        putExtra(
                            CalendarContract.Events.TITLE,
                            args?.get("title")?.toString() ?: "",
                        )
                    },
                    "opened a new event",
                    "Open with",
                )
                "openChooser" -> startActionIntentChooser(
                    Intent(Intent.ACTION_VIEW, Uri.parse(
                        args?.get("url")?.toString() ?: "")),
                    "opened link",
                    args?.get("title")?.toString() ?: "Open with",
                )
                "torch" -> setTorch(args?.get("mode")?.toString() != "off")
                "battery" -> batteryStatus()
                "volume" -> adjustVolume(
                    args?.get("mode")?.toString() ?: "up",
                    (args?.get("level") as? Number)?.toInt(),
                )
                "openApp" -> openApp(
                    args?.get("query")?.toString() ?: "",
                    args?.get("hint")?.toString(),
                )
                "closeApp" -> closeApp(
                    args?.get("query")?.toString() ?: "",
                    args?.get("hint")?.toString(),
                )
                // sendText is intercepted in the channel handler — it resolves
                // the recipient like calls do, which may request READ_CONTACTS.
                "mediaControl" -> mediaControl(args?.get("mode")?.toString() ?: "play")
                "wifi" -> openSettingsPanel(
                    Settings.ACTION_WIFI_SETTINGS,
                    "Apps can't switch Wi-Fi for you — I opened the Wi-Fi settings, flip the switch there.",
                )
                "bluetooth" -> openSettingsPanel(
                    Settings.ACTION_BLUETOOTH_SETTINGS,
                    "Apps can't switch Bluetooth for you — I opened the Bluetooth settings, flip the switch there.",
                )
                "brightness" -> setBrightness(
                    args?.get("mode")?.toString() ?: "up",
                    (args?.get("level") as Number?)?.toInt(),
                )
                "lock" -> mapOf(
                    "ok" to false,
                    "message" to "I can't lock the screen from an app — use the power button.",
                )
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

    /// Launches [intent] through the system app chooser, so "navigate to X"
    /// lets the user pick Maps, Waze, … instead of silently defaulting to
    /// one app. The chosen app is remembered by Android for next time.
    private fun startActionIntentChooser(
        intent: Intent,
        done: String,
        title: String,
    ): Map<String, Any?> {
        val chooser = Intent.createChooser(intent, title).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        startActivity(chooser)
        Log.i(TAG, done)
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

    private fun adjustVolume(mode: String, level: Int? = null): Map<String, Any?> {
        val am = getSystemService(AudioManager::class.java)
        when (mode) {
            "mute" -> am.adjustStreamVolume(
                AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, 0)
            "down" -> am.adjustStreamVolume(
                AudioManager.STREAM_MUSIC, AudioManager.ADJUST_LOWER, 0)
            "set" -> {
                // "volume 50" — scale the 0-100 level onto the stream's real
                // range so it maps to the same loudness on every device.
                val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                val clamped = (level ?: 50).coerceIn(0, 100)
                am.setStreamVolume(
                    AudioManager.STREAM_MUSIC,
                    (clamped * max) / 100,
                    0,
                )
                return mapOf("ok" to true, "message" to "Volume set to $clamped%.")
            }
            else -> am.adjustStreamVolume(
                AudioManager.STREAM_MUSIC, AudioManager.ADJUST_RAISE, 0)
        }
        return mapOf("ok" to true, "message" to "Volume $mode.")
    }

    /// Opens an installed app by name. The Dart side usually knows the exact
    /// package (its alias map), which is tried first; otherwise the display
    /// name of every installed app is fuzzy-matched, so "open deezer" and
    /// "launch the music app" both work. An app process can't run
    /// `/system/bin/am` (Android denies it to non-shell UIDs), so this uses
    /// the real launcher Intent instead.
    private fun openApp(query: String, hint: String?): Map<String, Any?> {
        // 1) Exact package from the alias map, when installed.
        hint?.trim()?.takeIf { it.isNotEmpty() }?.let { pkg ->
            if (tryLaunch(pkg)) return mapOf("ok" to true, "message" to "Opened $query.")
        }
        val q = contactMatchKey(query)
        if (q.isEmpty()) {
            return mapOf("ok" to false, "message" to "What app should I open?")
        }
        // 2) Fuzzy-match display names of every launchable app.
        val launcher = Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER)
        val hits = packageManager
            .queryIntentActivities(launcher, 0)
            .mapNotNull { ri ->
                val label = ri.loadLabel(packageManager)?.toString() ?: return@mapNotNull null
                val labelKey = contactMatchKey(label)
                val pkgKey = contactMatchKey(ri.activityInfo.packageName)
                val score = when {
                    labelKey == q -> 4
                    pkgKey == q -> 3
                    labelKey.startsWith(q) -> 2
                    pkgKey.contains(q) && q.length >= 2 -> 3
                    labelKey.contains(q) && q.length >= 2 -> 1
                    else -> return@mapNotNull null
                }
                Triple(ri, label, score)
            }
            .distinctBy { it.first.activityInfo.packageName }
            .sortedByDescending { it.third }
        hits.firstOrNull()?.let { (ri, label, _) ->
            if (tryLaunch(ri.activityInfo.packageName)) {
                return mapOf("ok" to true, "message" to "Opened $label.")
            }
            // Some odd launchers hide the launch intent; open the activity.
            return try {
                val direct = Intent(Intent.ACTION_MAIN)
                    .addCategory(Intent.CATEGORY_LAUNCHER)
                    .setClassName(ri.activityInfo.packageName, ri.activityInfo.name)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
                startActivity(direct)
                mapOf("ok" to true, "message" to "Opened $label.")
            } catch (e: Exception) {
                Log.e(TAG, "direct launch of $label failed", e)
                mapOf("ok" to false, "message" to "Could not open \"$query\".")
            }
        }
        val suggestions = hits.take(3).joinToString { it.second }
        return mapOf(
            "ok" to false,
            "message" to if (suggestions.isEmpty())
                "I couldn't find an app named \"$query\"."
            else
                "I couldn't find \"$query\" — did you mean $suggestions?",
        )
    }

    /// Returns true when [pkg] has a launcher entry and the launch succeeded.
    private fun tryLaunch(pkg: String): Boolean {
        val intent = packageManager.getLaunchIntentForPackage(pkg) ?: return false
        return try {
            startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            true
        } catch (e: Exception) {
            Log.e(TAG, "launch $pkg failed", e)
            false
        }
    }

    /// Stops a background app by package. Foreground apps can't be killed
    /// from another app without root — Android only allows background ones.
    private fun closeApp(query: String, hint: String?): Map<String, Any?> {
        val pkg = hint?.trim()?.takeIf { it.isNotEmpty() }
        if (pkg == null || packageManager.getLaunchIntentForPackage(pkg) == null) {
            return mapOf("ok" to false, "message" to "I couldn't find \"$query\" to close.")
        }
        getSystemService(ActivityManager::class.java).killBackgroundProcesses(pkg)
        return mapOf("ok" to true, "message" to "Closed $query.")
    }

    /// "text mom": resolves the recipient's number (READ_CONTACTS requested
    /// on first use, result held across the dialog) and opens the SMS
    /// composer prefilled with the number and draft — mirror of the call
    /// path, honest at every step.
    private fun sendText(
        contact: String,
        number: String?,
        body: String?,
        result: MethodChannel.Result,
    ) {
        val name = contact.trim()
        if (name.isEmpty()) {
            result.success(mapOf("ok" to false, "message" to "Who should I text?"))
            return
        }
        val known = number?.trim().orEmpty()
        if (known.isNotEmpty()) {
            // Nexus was taught this contact's number — use it directly,
            // skipping the address book (which also works when the name is
            // only in nexus memory, not in the device contacts).
            result.success(
                openSmsComposer(name, e164Number(known, simCountryIso()), body),
            )
            return
        }
        if (checkSelfPermission(Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            pendingTextContact = name
            pendingTextBody = body
            pendingTextResult = result
            requestPermissions(arrayOf(Manifest.permission.READ_CONTACTS), REQUEST_TEXT_PERMISSIONS)
            return
        }
        finishText(name, body, result)
    }

    /// Resolves [name] and completes [result] with the outcome. When there is
    /// no explicit body and the whole phrase doesn't match a contact, the
    /// trailing words are treated as the message — "text mom love you" or
    /// French "texte papi salut" resolve mom/papi with "love you"/"salut"
    /// as the draft, instead of failing on a contact named "mom love you".
    private fun finishText(name: String, body: String?, result: MethodChannel.Result) {
        var contact = name.trim()
        var msgBody = body
        val (number, matched, ranked) = lookupContacts(contact)
        if (number == null && body == null) {
            val words = contact.split(Regex("\\s+"))
            for (i in words.size - 1 downTo 1) {
                val probe = lookupContacts(words.take(i).joinToString(" "))
                if (probe.first != null) {
                    contact = words.take(i).joinToString(" ")
                    msgBody = words.drop(i).joinToString(" ")
                    openSmsComposer(contact, probe.first!!, msgBody)
                        .also { result.success(it) }
                    return
                }
            }
        }
        result.success(
            when {
                number != null -> openSmsComposer(contact, number, msgBody)
                else -> noContactResult(contact, ranked, matched, verb = "text them")
            }
        )
    }

    /// "what is the weather" without a city: one-time coarse location grant,
    /// then the best fix we can get quickly. The result resolves with a
    /// {lat, lon} map or null — the Dart side falls back to IP detection,
    /// never a dead end.
    private fun requestLocation(result: MethodChannel.Result) {
        if (checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            pendingLocationResult = result
            requestPermissions(
                arrayOf(Manifest.permission.ACCESS_COARSE_LOCATION),
                REQUEST_LOCATION_PERMISSIONS,
            )
            return
        }
        resolveLocation(result)
    }

    /// Best fix within ~6s: the most recent cached fix first (fast, and
    /// usually fresh enough for weather), then a one-shot network fix.
    /// Times out honestly to null rather than blocking the assistant.
    private fun resolveLocation(result: MethodChannel.Result) {
        val lm = getSystemService(LocationManager::class.java)
        try {
            val cached = listOf(
                LocationManager.NETWORK_PROVIDER,
                LocationManager.GPS_PROVIDER,
            ).firstNotNullOfOrNull { provider ->
                try {
                    lm.getLastKnownLocation(provider)
                } catch (e: SecurityException) {
                    null
                }
            }
            if (cached != null) {
                result.success(
                    mapOf("ok" to true, "lat" to cached.latitude, "lon" to cached.longitude),
                )
                return
            }
            // No cache: ask for one quick network fix. A 6s timeout keeps the
            // assistant honest instead of waiting forever indoors.
            pendingLocationResult = result
            Handler(Looper.getMainLooper()).postDelayed(locationTimeout, 6000)
            lm.requestSingleUpdate(
                LocationManager.NETWORK_PROVIDER,
                locationListener,
                Looper.getMainLooper(),
            )
        } catch (e: Exception) {
            Log.e(TAG, "location resolve failed", e)
            result.success(null)
        }
    }

    private val locationListener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            finishLocation(location)
        }

        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}

        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
    }

    private fun finishLocation(location: Location?) {
        val result = pendingLocationResult ?: return
        pendingLocationResult = null
        Handler(Looper.getMainLooper()).removeCallbacks(locationTimeout)
        try {
            getSystemService(LocationManager::class.java)
                .removeUpdates(locationListener)
        } catch (e: Exception) {
            // best effort — the listener dies with the activity anyway
        }
        result.success(
            if (location != null)
                mapOf("ok" to true, "lat" to location.latitude, "lon" to location.longitude)
            else null,
        )
    }

    /// "email mom": resolves the recipient's address from the address book
    /// (READ_CONTACTS requested on first use, result held across the dialog)
    /// and opens the mail composer with the address and draft — mirror of
    /// the text path, honest at every step.
    private fun sendEmail(
        contact: String,
        body: String?,
        result: MethodChannel.Result,
    ) {
        val name = contact.trim()
        if (name.isEmpty()) {
            result.success(mapOf("ok" to false, "message" to "Who should I email?"))
            return
        }
        if (checkSelfPermission(Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            pendingEmailContact = name
            pendingEmailBody = body
            pendingEmailResult = result
            requestPermissions(arrayOf(Manifest.permission.READ_CONTACTS), REQUEST_EMAIL_PERMISSIONS)
            return
        }
        finishEmail(name, body, result)
    }

    /// Resolves [name]'s address and completes [result] with the outcome.
    private fun finishEmail(name: String, body: String?, result: MethodChannel.Result) {
        val (address, matched, ranked) = lookupContactEmail(name)
        result.success(
            when {
                address != null -> openMailComposer(name, address, body)
                else -> noContactResult(name, ranked, matched, verb = "email them")
            }
        )
    }

    /// Opens the mail composer addressed to [address] with [body] drafted.
    private fun openMailComposer(name: String, address: String, body: String?): Map<String, Any?> = try {
        val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:$address")).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (!body.isNullOrBlank()) putExtra(Intent.EXTRA_TEXT, body)
        }
        startActivity(intent)
        mapOf("ok" to true, "message" to "Opened an email to $name — ready to send.")
    } catch (e: Exception) {
        Log.e(TAG, "could not open the mail composer", e)
        mapOf("ok" to false, "message" to "Could not open your mail app.")
    }

    /// Best email address for [name] plus the closest matching display
    /// names. Returns (address-or-null, matched-name-or-null, ranked). Only
    /// an exact or case-insensitive full name match is trusted; looser
    /// matches come back as candidates so the assistant can ask "who did you
    /// mean?" like calls and texts do.
    private fun lookupContactEmail(name: String): Triple<String?, String?, List<String>> {
        return try {
            val uri = ContactsContract.CommonDataKinds.Email.CONTENT_URI
            val projection = arrayOf(
                ContactsContract.CommonDataKinds.Email.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Email.ADDRESS,
            )
            contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                // First non-blank address wins per display name.
                val addressByName = LinkedHashMap<String, String>()
                val allNames = LinkedHashSet<String>()
                while (cursor.moveToNext()) {
                    val displayName = cursor.getString(0) ?: continue
                    allNames.add(displayName)
                    val address = cursor.getString(1)
                    if (!address.isNullOrBlank()) addressByName.putIfAbsent(displayName, address)
                }
                val q = name.trim()
                val lower = contactMatchKey(q)
                if (lower.isEmpty()) return@use Triple(null, null, emptyList())
                val matched = allNames.firstOrNull { contactMatchKey(it) == lower }
                    ?: if (lower.length >= 3) allNames.firstOrNull {
                        Regex("\\b" + Regex.escape(lower)).containsMatchIn(contactMatchKey(it))
                    } else null
                val address = matched?.let { addressByName[it] }
                val ranked = rankedContactMatches(addressByName.keys.toList(), name)
                Triple(address, matched, ranked)
            } ?: Triple(null, null, emptyList())
        } catch (e: Exception) {
            Log.e(TAG, "email lookup failed", e)
            Triple(null, null, emptyList())
        }
    }

    /// Voice input: RECORD_AUDIO is requested on first use, then one
    /// utterance is recognized and its text comes back to the composer.
    private fun listenSpeech(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            pendingSpeechResult = result
            ActivityCompat.requestPermissions(
                this,
                arrayOf(Manifest.permission.RECORD_AUDIO),
                REQUEST_SPEECH_PERMISSIONS,
            )
            return
        }
        startSpeech(result)
    }

    private fun startSpeech(result: MethodChannel.Result) {
        val recognizer = SpeechRecognizer.createSpeechRecognizer(this)
        recognizer.setRecognitionListener(object : RecognitionListener {
            override fun onResults(results: Bundle?) {
                val text = results
                    ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                    ?.firstOrNull()
                recognizer.destroy()
                result.success(text)
            }

            override fun onError(error: Int) {
                recognizer.destroy()
                result.success(null) // nothing heard / mic unavailable
            }

            override fun onBeginningOfSpeech() {}
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onEvent(eventType: Int, params: Bundle?) {}
            override fun onPartialResults(partialResults: Bundle?) {}
            override fun onReadyForSpeech(params: Bundle?) {}
            override fun onRmsChanged(rmsdB: Float) {}
        })
        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(
                RecognizerIntent.EXTRA_LANGUAGE_MODEL,
                RecognizerIntent.LANGUAGE_MODEL_FREE_FORM,
            )
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, false)
        }
        recognizer.startListening(intent)
    }

    /// "video call mom on whatsapp": only ever opens a video call in an app
    /// the user named — a bare "video call mom" gets an honest which-app
    /// reply, never a silent default or a phone call.
    private fun videoCall(contact: String, app: String?, result: MethodChannel.Result) {
        val name = contact.trim()
        if (name.isEmpty()) {
            result.success(mapOf("ok" to false, "message" to "Who should I video call?"))
            return
        }
        val appName = app?.trim()?.lowercase()?.replace(" ", "") ?: ""
        if (appName.isEmpty()) {
            result.success(mapOf(
                "ok" to false,
                "message" to "I only start video calls in an app you name — try \"video call " +
                    "$name on whatsapp\" (WhatsApp or Telegram).",
            ))
            return
        }
        if (checkSelfPermission(Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            pendingVideoContact = name
            pendingVideoApp = appName
            pendingVideoResult = result
            requestPermissions(arrayOf(Manifest.permission.READ_CONTACTS), REQUEST_VIDEO_PERMISSIONS)
            return
        }
        finishVideo(name, appName, result)
    }

    private fun finishVideo(name: String, app: String, result: MethodChannel.Result) {
        val (number, matched, ranked) = lookupContacts(name)
        result.success(
            when {
                number != null -> openVideoApp(name, app, number)
                else -> noContactResult(name, ranked, matched, verb = "video call them")
            }
        )
    }

    /// Opens the named app pointed at [number]. WhatsApp (wa.me) and Telegram
    /// (tg://resolve) have deep links that land on a callable contact;
    /// [number] arrives already E.164-normalized from [lookupContacts].
    /// Everything else — including Skype, whose consumer service was retired
    /// in 2025 — is answered honestly instead of pretending.
    private fun openVideoApp(name: String, app: String, number: String): Map<String, Any?> {
        val digits = number.removePrefix("+") // wa.me / tg:// resolve want no + sign
        val uri = when (app) {
            "whatsapp", "wa" -> "https://wa.me/$digits"
            "telegram", "tg" -> "tg://resolve?phone=$digits"
            else -> null
        }
        if (uri != null) {
            return try {
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(uri)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                mapOf(
                    "ok" to true,
                    "message" to "Opened ${displayAppName(app)} with $name — tap the video icon to start the call.",
                )
            } catch (e: Exception) {
                Log.e(TAG, "could not open $app for $name", e)
                mapOf("ok" to false, "message" to "Could not open ${displayAppName(app)}.")
            }
        }
        val label = displayAppName(app)
        val message = when (app) {
            "facetime" -> "FaceTime is Apple-only — on this Android, try \"video call " +
                "$name on whatsapp\" (WhatsApp or Telegram)."
            "skype" -> "Skype was retired in 2025 — try \"video call $name on whatsapp\" " +
                "(WhatsApp or Telegram)."
            "meet", "googlemeet", "zoom", "teams", "discord", "signal" ->
                "I can't start a $label video call to a phone number — open $label " +
                    "and start the call yourself. I can do WhatsApp or Telegram."
            else -> "I don't know how to video call on \"$label\" — I can open " +
                "WhatsApp or Telegram with $name."
        }
        return mapOf("ok" to false, "message" to message)
    }

    /// Normalizes a stored contact number to international form with a
    /// leading "+" and digits only: trims spaces/dashes/parens/dots,
    /// converts a "00" trunk prefix to "+", and prefixes the device's own
    /// country code when the number is national (a French "06 09 33 06 28"
    /// becomes +33609330628). Numbers that are already international or that
    /// carry an unknown country code are passed through as-is.
    private fun e164Number(raw: String, countryIso: String?): String {
        var t = raw.trim()
        if (t.startsWith("00") && t.length > 2) t = "+" + t.substring(2)
        val cleaned = t.filter { it.isDigit() || it == '+' }
        if (cleaned.startsWith("+")) return cleaned
        val code = countryIso?.let { COUNTRY_CALLING_CODES[it] } ?: return cleaned
        // Most countries drop the trunk "0" in international form; Italy
        // keeps it in E.164 mobile numbers, so leave it there.
        val national = if (code == "39") cleaned else cleaned.removePrefix("0")
        return "+$code$national"
    }

    private fun simCountryIso(): String? = try {
        val tm = getSystemService(TelephonyManager::class.java)
        (tm.simCountryIso?.takeIf { it.isNotBlank() }
            ?: tm.networkCountryIso?.takeIf { it.isNotBlank() })?.lowercase()
    } catch (e: Exception) {
        null
    }

    /// Friendly display name for an app key ("wa" -> "WhatsApp").
    private fun displayAppName(app: String): String = when (app) {
        "whatsapp", "wa" -> "WhatsApp"
        "telegram", "tg" -> "Telegram"
        "skype" -> "Skype"
        "facetime" -> "FaceTime"
        "googlemeet" -> "Google Meet"
        else -> app
    }

    /// Opens the SMS composer addressed to [number] (E.164 from
    /// [lookupContacts]) with [body] drafted.
    private fun openSmsComposer(name: String, number: String, body: String?): Map<String, Any?> = try {
        val intent = Intent(Intent.ACTION_SENDTO, Uri.fromParts("smsto", number, null)).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (!body.isNullOrBlank()) {
                putExtra("sms_body", body)
                putExtra(Intent.EXTRA_TEXT, body)
            }
        }
        startActivity(intent)
        mapOf("ok" to true, "message" to "Opened a text to $name — ready to send.")
    } catch (e: Exception) {
        Log.e(TAG, "could not open the SMS composer", e)
        mapOf("ok" to false, "message" to "Could not open messaging.")
    }

    /// Sends the media key events most players honour: play, pause, skip.
    private fun mediaControl(mode: String): Map<String, Any?> {
        val key = when (mode) {
            "play" -> KeyEvent.KEYCODE_MEDIA_PLAY
            "pause" -> KeyEvent.KEYCODE_MEDIA_PAUSE
            "next" -> KeyEvent.KEYCODE_MEDIA_NEXT
            "previous" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
            else -> KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE
        }
        if (mode == "shuffle" || mode == "repeat") {
            return mapOf(
                "ok" to false,
                "message" to "Shuffle and repeat live inside the music app — I can only play, pause and skip.",
            )
        }
        val am = getSystemService(AudioManager::class.java)
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, key))
        am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, key))
        val verb = when (mode) {
            "pause" -> "Paused."
            "next" -> "Next track."
            "previous" -> "Previous track."
            else -> "Playing."
        }
        return mapOf("ok" to true, "message" to verb)
    }

    /// Opens a system settings panel (Wi-Fi, Bluetooth, display…).
    private fun openSettingsPanel(action: String, done: String): Map<String, Any?> = try {
        startActivity(Intent(action).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        mapOf("ok" to true, "message" to done)
    } catch (e: Exception) {
        Log.e(TAG, "$action unavailable", e)
        mapOf("ok" to false, "message" to "That setting isn't available on this device.")
    }

    /// Writes the brightness only when Nexus has the "modify system settings"
    /// access; otherwise it opens the display settings so the user can drag
    /// the slider themselves.
    private fun setBrightness(mode: String, level: Int?): Map<String, Any?> {
        if (!Settings.System.canWrite(this)) {
            return openSettingsPanel(
                Settings.ACTION_DISPLAY_SETTINGS,
                "I need the \"modify system settings\" access to set brightness — I opened the display settings instead.",
            )
        }
        val value = if (mode == "set" && level != null) {
            (level.coerceIn(0, 100) * 255) / 100
        } else {
            val cur = Settings.System.getInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS, 128)
            (cur + if (mode == "down") -26 else 26).coerceIn(1, 255)
        }
        Settings.System.putInt(
            contentResolver,
            Settings.System.SCREEN_BRIGHTNESS_MODE,
            Settings.System.SCREEN_BRIGHTNESS_MODE_MANUAL,
        )
        Settings.System.putInt(contentResolver, Settings.System.SCREEN_BRIGHTNESS, value)
        val pct = (value * 100) / 255
        return mapOf("ok" to true, "message" to "Brightness set to $pct%.")
    }

    /// Resolves a contact name and places the call directly (ACTION_CALL).
    /// Missing permissions are requested at runtime on first use; without
    /// CALL_PHONE it falls back to the prefilled dialer. When nothing
    /// callable matches, genuinely different closest names travel back so
    /// the assistant can ask "who did you mean?".
    private fun callContact(name: String, number: String?, result: MethodChannel.Result) {
        val contact = name.trim()
        if (contact.isEmpty()) {
            result.success(mapOf("placed" to false, "launched" to false, "candidates" to emptyList<String>(),
                "message" to "No contact name given."))
            return
        }
        if (!number.isNullOrBlank()) {
            // A taught number ("remember that mom is 06…") — no address-book
            // lookup, so no READ_CONTACTS prompt. Dial straight through when
            // CALL_PHONE is granted, otherwise prefill the dialer.
            val direct = if (checkSelfPermission(Manifest.permission.CALL_PHONE) ==
                PackageManager.PERMISSION_GRANTED
            ) placeCall(contact, number) else openDialer(contact, number)
            result.success(direct)
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
        val (foundNumber, matched, ranked) = lookupContacts(contact)
        result.success(
            when {
                foundNumber == null -> noContactResult(contact, ranked, matched)
                else -> placeCall(contact, foundNumber)
            }
        )
    }

    private fun noContactResult(
        name: String,
        ranked: List<String>,
        matched: String? = null,
        verb: String = "call it",
    ): Map<String, Any?> {
        if (matched != null) {
            // The contact exists, just not reachable — never pretend it's missing.
            return mapOf(
                "placed" to false,
                "launched" to false,
                "candidates" to emptyList<String>(),
                "message" to "I found \"$matched\" in your contacts, but it has no phone number saved — " +
                    "add one and I'll $verb."
            )
        }
        // Never offer the query itself back as a suggestion: "No contact named
        // X ... Did you mean X?" (or a case/spacing twin like TVCraft01) is a
        // contradiction, not a choice. Keep one spelling per real contact.
        val q = contactMatchKey(name)
        val suggestions = ranked
            .filter { contactMatchKey(it) != q }
            .distinctBy { contactMatchKey(it) }
            .take(3)
        val message = if (suggestions.isEmpty())
            "No contact named \"$name\" on this device — add them to your contacts and I'll find them."
        else
            "No contact named \"$name\" on this device. Did you mean " +
                suggestions.joinToString(", ") { "\"$it\"" } + "?"
        return mapOf(
            "placed" to false,
            "launched" to false,
            "candidates" to suggestions,
            "message" to message
        )
    }

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
    /// Returns (E.164-normalized number, matched-name-or-null, ranked).
    /// Only an exact or
    /// case-insensitive-full name match is trusted enough to dial
    /// immediately; looser matches come back as candidates so the assistant
    /// can ask "who did you mean?" and learn the wording.
    private fun lookupContacts(name: String): Triple<String?, String?, List<String>> {
        return try {
            val uri = ContactsContract.CommonDataKinds.Phone.CONTENT_URI
            val projection = arrayOf(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
            )
            contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                // First non-blank number wins per display name; rows without
                // a number are tracked separately so we can tell "no contact"
                // apart from "contact with no number".
                val numberByName = LinkedHashMap<String, String>()
                val allNames = LinkedHashSet<String>()
                while (cursor.moveToNext()) {
                    val displayName = cursor.getString(0) ?: continue
                    allNames.add(displayName)
                    val number = cursor.getString(1)
                    if (!number.isNullOrBlank()) numberByName.putIfAbsent(displayName, number)
                }
                val q = name.trim()
                val lower = contactMatchKey(q)
                if (lower.isEmpty()) return@use Triple(null, null, emptyList())
                // Exact (case/accents folded) match dials straight away. When
                // the user's wording is a word inside a longer display name
                // ("call TVcraft01" -> "TVcraft01 Dad"), a strong word-boundary
                // substring match dials too — the full word they said is right
                // there in the contact name. Short queries stay exact-only so
                // "call a" never rings Anna by accident.
                val matched = allNames.firstOrNull { contactMatchKey(it) == lower }
                    ?: if (lower.length >= 3) allNames.firstOrNull {
                        Regex("\\b" + Regex.escape(lower)).containsMatchIn(contactMatchKey(it))
                    } else null
                // Normalize once, here, so calls, the dialer fallback, texts
                // and video all receive the same clean international number.
                val number = matched?.let { numberByName[it] }
                    ?.let { e164Number(it, simCountryIso()) }
                val ranked = rankedContactMatches(numberByName.keys.toList(), name)
                Triple(number, matched, ranked)
            } ?: Triple(null, null, emptyList())
        } catch (e: Exception) {
            Log.e(TAG, "contact lookup failed", e)
            Triple(null, null, emptyList())
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

/// ISO-3166 alpha-2 country codes (lowercase) to international calling
/// codes, used to turn national contact numbers ("06 09 33 06 28") into the
/// full international form wa.me and tg:// resolve require.
val COUNTRY_CALLING_CODES: Map<String, String> = mapOf(
    // NANP (+1)
    "us" to "1", "ca" to "1", "ag" to "1", "ai" to "1", "bb" to "1", "bs" to "1",
    "dm" to "1", "do" to "1", "gd" to "1", "jm" to "1", "kn" to "1", "ky" to "1",
    "lc" to "1", "tt" to "1",
    // +7
    "ru" to "7", "kz" to "7",
    // +20 - +39
    "eg" to "20", "za" to "27", "gr" to "30", "nl" to "31", "be" to "32",
    "fr" to "33", "es" to "34", "hu" to "36", "it" to "39",
    // +40 - +58
    "ro" to "40", "ch" to "41", "at" to "43", "gb" to "44", "dk" to "45",
    "se" to "46", "no" to "47", "pl" to "48", "de" to "49", "pe" to "51",
    "mx" to "52", "cu" to "53", "ar" to "54", "br" to "55", "cl" to "56",
    "co" to "57", "ve" to "58",
    // +60 - +98
    "my" to "60", "au" to "61", "id" to "62", "ph" to "63", "nz" to "64",
    "sg" to "65", "th" to "66", "jp" to "81", "kr" to "82", "vn" to "84",
    "cn" to "86", "tr" to "90", "in" to "91", "pk" to "92", "af" to "93",
    "lk" to "94", "mm" to "95", "ir" to "98",
    // +212 - +299
    "ma" to "212", "dz" to "213", "tn" to "216", "ly" to "218", "gm" to "220",
    "sn" to "221", "mr" to "222", "ml" to "223", "gn" to "224", "ci" to "225",
    "bf" to "226", "ne" to "227", "tg" to "228", "bj" to "229", "mu" to "230",
    "lr" to "231", "sl" to "232", "gh" to "233", "ng" to "234", "td" to "235",
    "cf" to "236", "cm" to "237", "cv" to "238", "st" to "239", "gq" to "240",
    "ga" to "241", "cg" to "242", "cd" to "243", "ao" to "244", "gw" to "245",
    "sc" to "248", "sd" to "249", "rw" to "250", "et" to "251", "so" to "252",
    "dj" to "253", "ke" to "254", "tz" to "255", "ug" to "256", "bi" to "257",
    "mz" to "258", "zm" to "260", "mg" to "261", "zw" to "263", "na" to "264",
    "mw" to "265", "ls" to "266", "bw" to "267", "sz" to "268", "km" to "269",
    // +350 - +389
    "gi" to "350", "pt" to "351", "lu" to "352", "ie" to "353", "is" to "354",
    "al" to "355", "mt" to "356", "cy" to "357", "fi" to "358", "bg" to "359",
    "lt" to "370", "lv" to "371", "ee" to "372", "md" to "373", "am" to "374",
    "by" to "375", "ad" to "376", "mc" to "377", "sm" to "378", "va" to "379",
    "ua" to "380", "rs" to "381", "me" to "382", "xk" to "383", "hr" to "385",
    "si" to "386", "ba" to "387", "mk" to "389",
    // +420 - +995
    "cz" to "420", "sk" to "421", "ge" to "995", "az" to "994",
    "tj" to "992", "tm" to "993", "uz" to "998", "kg" to "996", "mn" to "976",
    "kh" to "855", "la" to "856", "bt" to "975", "mv" to "960", "bd" to "880",
    "np" to "977", "il" to "972", "jo" to "962", "lb" to "961", "sa" to "966",
    "ae" to "971", "qa" to "974", "kw" to "965", "bh" to "973", "om" to "968",
    "ye" to "967", "iq" to "964", "sy" to "963",
    // Asia / Oceania
    "hk" to "852", "mo" to "853", "tw" to "886", "fj" to "679", "pg" to "675",
    "sb" to "677", "vu" to "678", "ws" to "685", "to" to "676",
)

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
        candidates.asSequence().filter {
            // Word-boundary contains: "call tom" must offer Tom, never Atom —
            // but "TVcraft01" inside "TVcraft01 Dad" is a real hit.
            Regex("\\b" + Regex.escape(lower)).containsMatchIn(contactMatchKey(it))
        },
    )
        .flatten()
        .distinct()
        .take(limit)
        .toList()
}
