package dev.nexus.nexus

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
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

    // "call mom" from the assistant: resolving a contact needs READ_CONTACTS,
    // so the dial waits for the runtime permission dialog. The MethodChannel
    // result is held across the round-trip so the reply confirms the launch.
    private val REQUEST_CONTACTS_PERMISSION = 42602
    private var pendingContactName: String? = null
    private var pendingDialResult: MethodChannel.Result? = null

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

        // "call mom" from the assistant: resolve the contact and open the
        // system dialer with the number prefilled (ACTION_DIAL — no call
        // permission needed).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PHONE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "dialContact" -> dialContact(call.argument<String>("name") ?: "", result)
                    else -> result.notImplemented()
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
        if (requestCode == REQUEST_CONTACTS_PERMISSION) {
            val name = pendingContactName
            val result = pendingDialResult
            pendingContactName = null
            pendingDialResult = null
            if (result != null) {
                val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
                result.success(
                    if (granted && name != null) dialContactNumber(name)
                    else mapOf(
                        "launched" to false,
                        "number" to null,
                        "message" to "Contacts permission was not granted."
                    )
                )
            }
        }
    }

    /// Resolves a contact name to a number and opens the dialer. Requests
    /// READ_CONTACTS at runtime if needed, holding the result until the user
    /// answers so the reply can confirm the launch.
    private fun dialContact(name: String, result: MethodChannel.Result) {
        val contact = name.trim()
        if (contact.isEmpty()) {
            result.success(
                mapOf("launched" to false, "number" to null, "message" to "No contact name given.")
            )
            return
        }
        if (checkSelfPermission(Manifest.permission.READ_CONTACTS) != PackageManager.PERMISSION_GRANTED) {
            pendingContactName = contact
            pendingDialResult = result
            requestPermissions(
                arrayOf(Manifest.permission.READ_CONTACTS),
                REQUEST_CONTACTS_PERMISSION
            )
            return
        }
        result.success(dialContactNumber(contact))
    }

    /// Looks up the first phone number for [name] and opens the dialer with
    /// it prefilled. The [Map] result is what the assistant sends back.
    private fun dialContactNumber(name: String): Map<String, Any?> {
        val number = lookupContactNumber(name)
        if (number == null) {
            return mapOf(
                "launched" to false,
                "number" to null,
                "message" to "No contact named \"$name\" on this device."
            )
        }
        return try {
            val intent = Intent(Intent.ACTION_DIAL, Uri.fromParts("tel", number, null)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            Log.i(TAG, "opened dialer for $name ($number)")
            mapOf(
                "launched" to true,
                "number" to number,
                "message" to "Opened the dialer for $name ($number)."
            )
        } catch (e: Exception) {
            Log.e(TAG, "could not open the dialer", e)
            mapOf(
                "launched" to false,
                "number" to number,
                "message" to "Could not open the dialer."
            )
        }
    }

    /// Phone number of the contact whose display name best matches [name]
    /// (exact first, ranked fallback — see [pickBestContactMatch]).
    private fun lookupContactNumber(name: String): String? {
        return try {
            val uri = ContactsContract.CommonDataKinds.Phone.CONTENT_URI
            val projection = arrayOf(
                ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                ContactsContract.CommonDataKinds.Phone.NUMBER,
            )
            contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
                // First number wins per display name, mirroring the old
                // "moveToFirst" behavior for exact matches.
                val numberByName = LinkedHashMap<String, String>()
                while (cursor.moveToNext()) {
                    val displayName = cursor.getString(0) ?: continue
                    numberByName.putIfAbsent(displayName, cursor.getString(1))
                }
                val matched = pickBestContactMatch(numberByName.keys.toList(), name)
                matched?.let { numberByName[it] }
            }
        } catch (e: Exception) {
            Log.e(TAG, "contact lookup failed", e)
            null
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
fun pickBestContactMatch(candidates: List<String>, query: String): String? {
    val q = query.trim()
    if (q.isEmpty()) return null
    val lower = q.lowercase()
    return candidates.firstOrNull { it == q }
        ?: candidates.firstOrNull { it.lowercase() == lower }
        ?: candidates.firstOrNull { it.lowercase().startsWith(lower) }
        ?: candidates.firstOrNull { it.lowercase().contains(lower) }
}
