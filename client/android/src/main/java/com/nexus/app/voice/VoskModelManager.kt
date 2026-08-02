package com.nexus.app.voice

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.util.zip.ZipInputStream

/**
 * Manages Vosk speech models for the Nexus wake-word engine.
 *
 * - The English model is bundled under assets/vosk-models/en and copied to the
 *   app-private files directory on first use.
 * - Other languages can be downloaded from the public Vosk model URLs.
 * - Switching languages deletes the previous active model to keep disk usage low.
 */
class VoskModelManager private constructor(private val context: Context) {

    data class Language(
        val code: String,
        val displayName: String,
        val downloadUrl: String,
        val bundled: Boolean = false
    )

    sealed class DownloadState {
        data object Idle : DownloadState()
        data class Downloading(val language: String, val progress: Float) : DownloadState()
        data class Success(val language: String) : DownloadState()
        data class Error(val language: String, val reason: String) : DownloadState()
    }

    private val prefs: SharedPreferences by lazy {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    private val _downloadState = MutableStateFlow<DownloadState>(DownloadState.Idle)
    val downloadState: StateFlow<DownloadState> = _downloadState.asStateFlow()

    private val _activeLanguage = MutableStateFlow(getActiveLanguage())
    val activeLanguage: StateFlow<String> = _activeLanguage.asStateFlow()

    private val _availableLanguages = MutableStateFlow(buildLanguageCatalog())
    val availableLanguages: StateFlow<List<Language>> = _availableLanguages.asStateFlow()

    /** Directory where the currently active model lives. */
    val activeModelDirectory: File
        get() = getModelDir(getActiveLanguage())

    companion object {
        const val PREFS_NAME = "vosk_model_prefs"
        const val KEY_ACTIVE_LANGUAGE = "active_language"

        // Assets path where the bundled English model lives.
        const val BUNDLED_EN_ASSETS_PATH = "vosk-models/en"

        // Well-known Vosk small model URLs. These are zipped archives that contain
        // a single model folder.
        private val LANGUAGE_CATALOG = listOf(
            Language(
                code = "en",
                displayName = "English",
                downloadUrl = modelUrl("vosk-model-small-en-us-0.15.zip"),
                bundled = true
            ),
            Language(
                code = "fr",
                displayName = "Français",
                downloadUrl = modelUrl("vosk-model-small-fr-0.22.zip")
            ),
            Language(
                code = "es",
                displayName = "Español",
                downloadUrl = modelUrl("vosk-model-small-es-0.22.zip")
            ),
            Language(
                code = "de",
                displayName = "Deutsch",
                downloadUrl = modelUrl("vosk-model-small-de-0.15.zip")
            ),
            Language(
                code = "it",
                displayName = "Italiano",
                downloadUrl = modelUrl("vosk-model-small-it-0.22.zip")
            ),
            Language(
                code = "pt",
                displayName = "Português",
                downloadUrl = modelUrl("vosk-model-small-pt-0.22.zip")
            ),
            Language(
                code = "ru",
                displayName = "Русский",
                downloadUrl = modelUrl("vosk-model-small-ru-0.22.zip")
            ),
            Language(
                code = "zh",
                displayName = "中文",
                downloadUrl = modelUrl("vosk-model-small-cn-0.22.zip")
            )
        )

        private const val FALLBACK_MODEL_BASE_URL = "https://alphacephei.com/vosk/models"

        private fun modelUrl(fileName: String): String {
            val base = try {
                com.nexus.app.BuildConfig.MODEL_BASE_URL.trimEnd('/')
            } catch (_: Throwable) {
                FALLBACK_MODEL_BASE_URL
            }
            return "$base/$fileName"
        }

        @Volatile
        private var instance: VoskModelManager? = null

        fun getInstance(context: Context): VoskModelManager {
            return instance ?: synchronized(this) {
                instance ?: VoskModelManager(context.applicationContext).also { instance = it }
            }
        }
    }

    private fun buildLanguageCatalog(): List<Language> = LANGUAGE_CATALOG

    fun getActiveLanguage(): String {
        return prefs.getString(KEY_ACTIVE_LANGUAGE, "en") ?: "en"
    }

    fun getModelDir(language: String): File {
        return File(context.filesDir, "vosk-models/$language")
    }

    /** Returns true if the model for [language] already exists on disk. */
    fun isModelReady(language: String): Boolean {
        return isValidModelDir(getModelDir(language))
    }

    /** Returns true if the directory contains a valid Vosk model. */
    private fun isValidModelDir(dir: File): Boolean {
        return dir.exists() && File(dir, "model.conf").exists()
    }

    /**
     * Search [root] and all of its subdirectories for a directory that contains
     * a Vosk model.conf file. Returns that directory, or null if none is found.
     */
    private fun findModelRoot(root: File): File? {
        if (!root.exists()) return null
        val stack = mutableListOf(root)
        while (stack.isNotEmpty()) {
            val current = stack.removeAt(stack.size - 1)
            if (File(current, "model.conf").exists()) {
                return current
            }
            current.listFiles()?.filter { it.isDirectory }?.let { stack.addAll(it) }
        }
        return null
    }

    /**
     * Returns true if a model is ready to use for [language].
     * For English, this also copies the bundled assets if present.
     */
    suspend fun ensureModel(language: String): Boolean = withContext(Dispatchers.IO) {
        val dir = getModelDir(language)
        if (isValidModelDir(dir)) {
            return@withContext true
        }
        if (dir.exists()) {
            // Remove a corrupt or placeholder model left from a previous run.
            dir.deleteRecursively()
        }
        if (language == "en") {
            return@withContext copyBundledEnglishModel()
        }
        false
    }

    /**
     * Copies the bundled English model from assets/vosk-models/en into the app's
     * files directory so Vosk can load it.
     */
    suspend fun copyBundledEnglishModel(): Boolean = withContext(Dispatchers.IO) {
        try {
            val assetFiles = context.assets.list(BUNDLED_EN_ASSETS_PATH) ?: emptyArray()
            if (assetFiles.isEmpty()) {
                Log.w("VoskModelManager", "No bundled English model found in assets/$BUNDLED_EN_ASSETS_PATH")
                return@withContext false
            }
            val targetDir = getModelDir("en")
            copyAssetsRecursively(BUNDLED_EN_ASSETS_PATH, targetDir)
            if (!isValidModelDir(targetDir)) {
                Log.w("VoskModelManager", "Bundled English model is incomplete (missing model.conf)")
                targetDir.deleteRecursively()
                return@withContext false
            }
            Log.i("VoskModelManager", "Bundled English model copied to ${targetDir.absolutePath}")
            true
        } catch (e: Exception) {
            Log.e("VoskModelManager", "Failed to copy bundled English model", e)
            false
        }
    }

    /**
     * Downloads a language model from the public Vosk URL, unzips it, sets it as
     * active, and removes the previous active model to save space.
     */
    suspend fun downloadAndActivateLanguage(language: String) = withContext(Dispatchers.IO) {
        val catalogLanguage = _availableLanguages.value.find { it.code == language }
            ?: throw IllegalArgumentException("Unknown language: $language")

        _downloadState.value = DownloadState.Downloading(language, 0f)

        val targetDir = getModelDir(language)
        targetDir.mkdirs()

        try {
            val url = URL(catalogLanguage.downloadUrl)
            val connection = openConnectionWithRedirects(url)
            connection.connectTimeout = 30_000
            connection.readTimeout = 30_000
            connection.setRequestProperty("User-Agent", "Nexus/1.0")
            connection.connect()

            val contentLength = connection.contentLength.toLong().coerceAtLeast(1L)
            val input = BufferedInputStream(connection.inputStream)

            val zipFile = File(context.cacheDir, "vosk-model-$language.zip")
            FileOutputStream(zipFile).use { output ->
                var downloaded: Long = 0
                val buffer = ByteArray(8192)
                var read: Int
                while (input.read(buffer).also { read = it } != -1) {
                    output.write(buffer, 0, read)
                    downloaded += read
                    val progress = (downloaded.toFloat() / contentLength).coerceIn(0f, 1f)
                    _downloadState.value = DownloadState.Downloading(language, progress)
                }
            }
            input.close()
            connection.disconnect()

            // Unzip into a temporary directory first to avoid leaving a half-extracted model.
            val tempDir = File(context.cacheDir, "vosk-model-$language-extract")
            unzip(zipFile, tempDir)
            zipFile.delete()

            // Vosk zips contain a single top-level folder. The exact nesting varies
            // between languages, so find the directory that actually contains model.conf.
            val modelRoot = findModelRoot(tempDir)
                ?: throw IOException("Could not find model.conf in downloaded archive")

            targetDir.deleteRecursively()
            if (!modelRoot.renameTo(targetDir)) {
                // Fallback: copy contents if rename fails (e.g. across filesystems).
                copyDirectory(modelRoot, targetDir)
            }
            tempDir.deleteRecursively()

            if (!isValidModelDir(targetDir)) {
                throw IOException("Downloaded model is incomplete (missing model.conf)")
            }

            setActiveLanguage(language)
            _downloadState.value = DownloadState.Success(language)
        } catch (e: Exception) {
            Log.e("VoskModelManager", "Failed to download model for $language", e)
            _downloadState.value = DownloadState.Error(language, e.message ?: "unknown error")
        }
    }

    /**
     * Switches the active language. The caller should restart the wake-word listener
     * so it loads the new model directory.
     */
    fun setActiveLanguage(language: String) {
        prefs.edit().putString(KEY_ACTIVE_LANGUAGE, language).apply()
        _activeLanguage.value = language
    }

    /**
     * Deletes every language model directory except the currently active one and,
     * if requested, the bundled English fallback.
     */
    fun pruneInactiveModels(keepEnglish: Boolean = true) {
        val active = getActiveLanguage()
        val root = File(context.filesDir, "vosk-models")
        root.listFiles()?.forEach { langDir ->
            val code = langDir.name
            if (code != active && (!keepEnglish || code != "en")) {
                try {
                    langDir.deleteRecursively()
                    Log.i("VoskModelManager", "Pruned inactive model: ${langDir.name}")
                } catch (e: Exception) {
                    Log.w("VoskModelManager", "Failed to prune ${langDir.name}", e)
                }
            }
        }
    }

    private fun copyAssetsRecursively(assetPath: String, targetDir: File) {
        targetDir.mkdirs()
        val assets = context.assets.list(assetPath) ?: return
        if (assets.isEmpty()) {
            // It's a file, copy it.
            context.assets.open(assetPath).use { input ->
                FileOutputStream(File(targetDir, assetPath.substringAfterLast("/"))).use { output ->
                    input.copyTo(output)
                }
            }
            return
        }
        for (asset in assets) {
            copyAssetsRecursively("$assetPath/$asset", File(targetDir, asset))
        }
    }

    private fun unzip(zipFile: File, targetDir: File) {
        targetDir.mkdirs()
        ZipInputStream(zipFile.inputStream()).use { zip ->
            var entry = zip.nextEntry
            while (entry != null) {
                val file = File(targetDir, entry.name)
                if (entry.isDirectory) {
                    file.mkdirs()
                } else {
                    file.parentFile?.mkdirs()
                    FileOutputStream(file).use { output -> zip.copyTo(output) }
                }
                zip.closeEntry()
                entry = zip.nextEntry
            }
        }
    }

    private fun copyDirectory(source: File, target: File) {
        target.mkdirs()
        source.walkTopDown().forEach { file ->
            val relative = file.relativeTo(source).path
            val dest = File(target, relative)
            if (file.isDirectory) {
                dest.mkdirs()
            } else {
                file.inputStream().use { input ->
                    FileOutputStream(dest).use { output -> input.copyTo(output) }
                }
            }
        }
    }

    private fun openConnectionWithRedirects(url: URL, maxRedirects: Int = 5): HttpURLConnection {
        var connection = url.openConnection() as HttpURLConnection
        connection.instanceFollowRedirects = false
        var redirects = 0
        while (connection.responseCode / 100 == 3 && redirects < maxRedirects) {
            val location = connection.getHeaderField("Location") ?: break
            connection.disconnect()
            connection = URL(location).openConnection() as HttpURLConnection
            connection.instanceFollowRedirects = false
            redirects++
        }
        val code = connection.responseCode
        if (code !in 200..299) {
            throw IOException("HTTP $code while downloading model from ${url.host}")
        }
        return connection
    }

    /** Returns the wake-word grammar string for the given language. */
    fun wakeWordGrammar(language: String): String {
        val phrase = when (language) {
            "fr" -> "salut nexus"
            "es" -> "hola nexus"
            "de" -> "hallo nexus"
            "it" -> "ciao nexus"
            "pt" -> "olá nexus"
            "ru" -> "привет nexus"
            "zh" -> "你好 nexus"
            else -> "hey nexus"
        }
        // JSON array with the wake phrase plus an unknown token.
        return "[\"$phrase\", \"[unk]\"]"
    }

    fun defaultEnglishGrammar(): String = wakeWordGrammar("en")
}
