package dev.nexus.nexus

// The eyes on Android: ML Kit, called directly.
//
// This replaces two Dart packages (google_mlkit_text_recognition and
// google_mlkit_image_labeling) with the same ML Kit artifacts, called here
// instead. The reason is on the other platform: those packages declare an iOS
// deployment target of 15.5, and Nexus has to run on an iPhone 6s on iOS 15.0.2.
// Dropping the pub dependencies removes the pods from the iOS build entirely,
// and Android keeps exactly the behaviour and the model versions it had
// (text-recognition 16.0.1, image-labeling 17.0.9 — see build.gradle.kts).
//
// The channel is deliberately thin: a path in, ML Kit's own answer out. No
// trimming, no de-duplication, no prompt building — those live in
// lib/core/ml_vision_service.dart, where both platforms share them and where
// they are already tested.
//
// The two recognisers are kept alive between calls on purpose. Both hold a
// loaded model, and building one per picture is the difference between "a pause"
// and "a pause every single time" on a phone that has to reload 2 MB of weights.

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.util.Log
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.label.ImageLabeler
import com.google.mlkit.vision.label.ImageLabeling
import com.google.mlkit.vision.label.defaults.ImageLabelerOptions
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class VisionBridge(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        /// Must match kVisionChannelName in lib/core/vision_engine.dart.
        const val CHANNEL = "dev.nexus.nexus/vision"
        private const val TAG = "NexusVision"

        /// The confidence floor the Dart package used by default. Below it ML Kit
        /// is guessing, and a guess in the prompt is worse than one fewer object.
        private const val MIN_LABEL_CONFIDENCE = 0.5f
    }

    // Held across calls so the loaded models are reused. Closed in [close].
    private var textRecognizer: TextRecognizer? = null
    private var imageLabeler: ImageLabeler? = null

    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    fun attach(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error("NO_PATH", "No image path was provided", null)
            return
        }
        when (call.method) {
            "recognizeText" -> recognizeText(path, result)
            "labelObjects" -> labelObjects(path, result)
            else -> result.notImplemented()
        }
    }

    /// The words in the picture, newlines preserved.
    private fun recognizeText(path: String, result: MethodChannel.Result) {
        executor.execute {
            val image = try {
                inputImage(path)
            } catch (error: Exception) {
                fail(result, "OCR_FAILED", error)
                return@execute
            }
            try {
                val recognizer = textRecognizer
                    ?: TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
                        .also { textRecognizer = it }
                recognizer.process(image)
                    .addOnSuccessListener { text ->
                        val body = text?.text ?: ""
                        main.post { result.success(body) }
                    }
                    .addOnFailureListener { error -> fail(result, "OCR_FAILED", error) }
            } catch (error: Exception) {
                fail(result, "OCR_FAILED", error)
            }
        }
    }

    /// The objects in the picture, best match first.
    ///
    /// Sorted here rather than in Dart because this is the side that knows what
    /// its own score means. The list is already above the confidence floor.
    private fun labelObjects(path: String, result: MethodChannel.Result) {
        executor.execute {
            val image = try {
                inputImage(path)
            } catch (error: Exception) {
                fail(result, "LABEL_FAILED", error)
                return@execute
            }
            try {
                val labeler = imageLabeler
                    ?: ImageLabeling.getClient(
                        ImageLabelerOptions.Builder()
                            .setConfidenceThreshold(MIN_LABEL_CONFIDENCE)
                            .build()
                    ).also { imageLabeler = it }
                labeler.process(image)
                    .addOnSuccessListener { labels ->
                        val payload = labels
                            .sortedByDescending { it.confidence }
                            .map {
                                mapOf(
                                    "label" to it.text,
                                    "confidence" to it.confidence.toDouble(),
                                )
                            }
                        main.post { result.success(payload) }
                    }
                    .addOnFailureListener { error -> fail(result, "LABEL_FAILED", error) }
            } catch (error: Exception) {
                fail(result, "LABEL_FAILED", error)
            }
        }
    }

    /// `InputImage.fromFilePath` reads the EXIF rotation itself, which is what
    /// keeps a photo taken sideways from being read sideways — the same call the
    /// Dart packages made on our behalf.
    private fun inputImage(path: String): InputImage =
        InputImage.fromFilePath(context, Uri.fromFile(File(path)))

    private fun fail(result: MethodChannel.Result, code: String, error: Throwable) {
        Log.w(TAG, "$code: ${error.message}")
        val message = error.message ?: "Could not read the image"
        main.post { result.error(code, message, null) }
    }

    /// Releases both models. Called from the activity's onDestroy so a closed
    /// app does not keep native weights resident.
    fun close() {
        textRecognizer?.close()
        textRecognizer = null
        imageLabeler?.close()
        imageLabeler = null
        executor.shutdown()
    }
}
