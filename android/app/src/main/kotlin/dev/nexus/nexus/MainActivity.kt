package dev.nexus.nexus

import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private val CHANNEL = "dev.nexus.nexus/installer"

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
            val file = File(path)
            if (!file.exists()) return false

            val uri: Uri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                // Android 7+ requires a ContentProvider URI.
                FileProvider.getUriForFile(
                    this,
                    "${applicationContext.packageName}.updater",
                    file
                )
            } else {
                Uri.fromFile(file)
            }

            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }
}
