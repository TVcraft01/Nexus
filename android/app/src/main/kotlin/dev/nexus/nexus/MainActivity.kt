package dev.nexus.nexus

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.util.Log
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "dev.nexus.nexus/installer"
    private val TAG = "NexusInstaller"

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
    }

    private fun installApk(path: String): Boolean {
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
            Log.e(TAG, "installApk failed", e)
            false
        }
    }
}
