package dev.nexus.nexus

import android.Manifest
import android.app.ActivityManager
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
import android.view.KeyEvent
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
                    "videoCall" -> videoCall(
                        call.argument<String>("name") ?: "",
                        call.argument<String>("app"),
                        result,
                    )
                    else -> result.notImplemented()
                }
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
                        args?.get("body")?.toString(),
                        result,
                    )
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
    private fun sendText(contact: String, body: String?, result: MethodChannel.Result) {
        val name = contact.trim()
        if (name.isEmpty()) {
            result.success(mapOf("ok" to false, "message" to "Who should I text?"))
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

    /// Resolves [name] and completes [result] with the outcome.
    private fun finishText(name: String, body: String?, result: MethodChannel.Result) {
        val (number, matched, ranked) = lookupContacts(name)
        result.success(
            when {
                number != null -> openSmsComposer(name, number, body)
                else -> noContactResult(name, ranked, matched, verb = "text them")
            }
        )
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
                    "$name on whatsapp\" (WhatsApp, Telegram or Skype).",
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

    /// Opens the named app pointed at [number]. Only WhatsApp, Telegram and
    /// Skype have a deep link that lands on a callable contact; everything
    /// else is answered honestly instead of pretending.
    private fun openVideoApp(name: String, app: String, number: String): Map<String, Any?> {
        val digits = number.filter { it.isDigit() || it == '+' }
        val uri = when (app) {
            "whatsapp", "wa" -> "https://wa.me/$digits"
            "telegram", "tg" -> "tg://msg?to=$digits"
            "skype" -> "skype:$digits?call&video=true"
            else -> null
        }
        if (uri != null) {
            return try {
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(uri)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                val message = if (app == "skype")
                    "Started a Skype video call to $name."
                else
                    "Opened ${displayAppName(app)} with $name — tap the video icon to start the call."
                mapOf("ok" to true, "message" to message)
            } catch (e: Exception) {
                Log.e(TAG, "could not open $app for $name", e)
                mapOf("ok" to false, "message" to "Could not open ${displayAppName(app)}.")
            }
        }
        val label = displayAppName(app)
        val message = when (app) {
            "facetime" -> "FaceTime is Apple-only — on this Android, try \"video call " +
                "$name on whatsapp\" (WhatsApp, Telegram or Skype)."
            "meet", "googlemeet", "zoom", "teams", "discord", "signal" ->
                "I can't start a $label video call to a phone number — open $label " +
                    "and start the call yourself. I can do WhatsApp, Telegram or Skype."
            else -> "I don't know how to video call on \"$label\" — I can open " +
                "WhatsApp, Telegram or Skype with $name."
        }
        return mapOf("ok" to false, "message" to message)
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

    /// Opens the SMS composer addressed to [number] with [body] drafted.
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
        val (number, matched, ranked) = lookupContacts(contact)
        result.success(
            when {
                number == null -> noContactResult(contact, ranked, matched)
                else -> placeCall(contact, number)
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
    /// Returns (number, matched-name-or-null, ranked). Only an exact or
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
                val matched = allNames.firstOrNull { contactMatchKey(it) == lower }
                val ranked = rankedContactMatches(numberByName.keys.toList(), name)
                Triple(matched?.let { numberByName[it] }, matched, ranked)
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
