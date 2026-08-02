package com.nexus.app.ui.viewmodel

import android.Manifest
import android.app.Application
import com.nexus.app.skill.SkillManifest
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.provider.Settings
import android.net.Uri
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.nexus.app.NexusApplication
import com.nexus.app.brain.AdaptiveEngine
import com.nexus.app.brain.BrainResponse
import com.nexus.app.brain.ChatMessage
import com.nexus.app.brain.DiscoveredBackend
import com.nexus.app.brain.LLMBackendDiscovery
import com.nexus.app.brain.NexusBrain
import com.nexus.app.command.CommandResult
import com.nexus.app.command.RoutineRepository
import com.nexus.app.command.RoutineSuggestion
import com.nexus.app.command.UserDialectRule
import com.nexus.app.command.UserRulesRepository
import com.nexus.app.command.ZeroLLMCommandEngine
import com.nexus.app.data.local.NexusDatabase
import com.nexus.app.data.local.entity.MemoryLogEntity
import com.nexus.app.hardware.ExecutionMode
import com.nexus.app.hardware.HardwareManager
import com.nexus.app.mesh.MeshNode
import com.nexus.app.mesh.TransportType
import com.nexus.app.security.SecurityGuard
import com.nexus.app.service.NexusMeshBinder
import com.nexus.app.service.NexusMeshService
import com.nexus.app.sound.SoundPairingManager
import com.nexus.app.voice.VoiceprintManager
import com.nexus.app.voice.VoskModelManager
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

enum class VoiceTarget { COMMAND, CHAT }

class NexusViewModel(application: Application) : AndroidViewModel(application) {

    private val nexusApplication: NexusApplication = application as NexusApplication
    private val hardwareManager: HardwareManager = nexusApplication.hardwareManager
    private val database: NexusDatabase by lazy { nexusApplication.database }
    private val userRulesRepository: UserRulesRepository by lazy { UserRulesRepository(application, database) }
    private val commandEngine: ZeroLLMCommandEngine by lazy { ZeroLLMCommandEngine(application, userRulesRepository, hardwareManager, database.noteDao(), nexusApplication.learningRepository, nexusApplication.capabilityRouter) }
    private val nexusBrain: NexusBrain by lazy { NexusBrain(application, commandEngine, database) }
    // Adaptive engine: the brain's learning layer that sits between voice
    // input and the rule engine, using usage patterns to improve over time.
    private val adaptiveEngine: AdaptiveEngine by lazy { nexusApplication.adaptiveEngine }
    private var chatBackend: DiscoveredBackend? = null
    // Use the application's shared instance so the mesh service's
    // onRoutinesChanged hook (broadcast on local handoff) observes the same store.
    private val routineRepository: RoutineRepository by lazy { nexusApplication.routineRepository }
    private val securityGuard = SecurityGuard.getInstance()

    private val _uiState = MutableStateFlow(NexusUiState())
    val uiState: StateFlow<NexusUiState> = _uiState.asStateFlow()

    private val _meshNodes = MutableStateFlow<List<MeshNode>>(emptyList())
    val meshNodes: StateFlow<List<MeshNode>> = _meshNodes.asStateFlow()

    private val _permissionRequest = MutableSharedFlow<Array<String>>()
    val permissionRequest = _permissionRequest.asSharedFlow()

    private val _voicePermissionResult = MutableSharedFlow<Boolean>()
    val voicePermissionResult = _voicePermissionResult.asSharedFlow()

    private var pendingCommandAfterPermission: String? = null
    private var pendingPermissions: Array<String>? = null
    private var pendingVoiceAfterPermission: Boolean = false
    var pendingVoiceTarget: VoiceTarget = VoiceTarget.COMMAND
        private set

    fun setPendingVoiceTarget(target: VoiceTarget) {
        pendingVoiceTarget = target
    }
    private var pendingWakeWordAfterPermission: Boolean = false

    private var meshService: NexusMeshService? = null
    private var serviceBound = false
    private var serviceBindingCount = 0
    private val bindingLock = Any()
    private var wakeWordJob: kotlinx.coroutines.Job? = null
    private var pendingWakeWordEnableAfterDownload: Boolean = false

    private val voskModelManager = VoskModelManager.getInstance(application)
    private val voiceprintManager = VoiceprintManager.getInstance(application)
    // Cached Vosk model for in-app voice input (loaded once, shared across
    // sessions, closed in onCleared). Tracked alongside the directory it came
    // from so a high-accuracy toggle can swap in the larger model.
    private var voiceModel: org.vosk.Model? = null
    private var voiceModelDir: String? = null

    private val _readyLanguages = MutableStateFlow<Set<String>>(
        if (voskModelManager.isModelReady("en")) setOf("en") else emptySet()
    )
    val readyLanguages: StateFlow<Set<String>> = _readyLanguages.asStateFlow()

    private val meshServiceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName?, service: IBinder?) {
            val binder = service as? NexusMeshBinder ?: return
            meshService = binder.getService()
            observeMeshNodes()
            observeWakeWordEvents()
            if (_uiState.value.wakeWordEnabled) {
                meshService?.setWakeWordEnabled(true)
            }
        }

        override fun onServiceDisconnected(name: ComponentName?) {
            meshService = null
        }
    }

    private val _wakeWordEvent = MutableSharedFlow<Unit>(extraBufferCapacity = 1)
    val wakeWordEvent = _wakeWordEvent.asSharedFlow()

    private val soundPairingManager = SoundPairingManager()

    // QR pairing state: when hosting a QR code, automatically pair with any
    // discovered node using the displayed PIN so the reverse side also stores
    // the shared key.
    private var activeQrPin: String? = null

    init {
        // Reflect the persisted hands-free-wake preference immediately, so the
        // toggle shows the right state (and the service re-enables the listener
        // on connect) even if the user closed and reopened the app.
        _uiState.value = _uiState.value.copy(
            wakeWordEnabled = voskModelManager.isWakeWordEnabled(),
            highAccuracyVoice = voskModelManager.isHighAccuracyVoiceEnabled(),
            highAccuracyVoiceReady = voskModelManager.isLargeEnglishModelReady(),
            oneShotWake = voskModelManager.isOneShotModeEnabled(),
            voiceprintEnrolled = voiceprintManager.isEnrolled(),
            voiceprintVerificationEnabled = voiceprintManager.isVerificationEnabled(),
            customWakePhrase = voiceprintManager.getCustomWakePhrase()
        )
        refreshBatteryOptimizationStatus()
        refreshHardwareProfile()
        startObservingLogs()
        startObservingRules()
        startObservingVoskModelState()
        startObservingLargeModelState()
        refreshReadyLanguages()
        startObservingRoutineSuggestions()
        refreshChatBackend()
        loadChatHistory()
        refreshSkills()
        // Kick off adaptive pattern discovery in the background
        viewModelScope.launch(Dispatchers.IO) {
            try { adaptiveEngine.maintain() } catch (_: Exception) { }
        }
    }

    override fun onCleared() {
        super.onCleared()
        try {
            voiceModel?.close()
        } catch (_: Exception) { }
        voiceModel = null
    }

    fun getAvailableLanguages(): List<VoskModelManager.Language> {
        return voskModelManager.availableLanguages.value
    }

    fun changeWakeWordLanguage(language: String) {
        viewModelScope.launch(Dispatchers.IO) {
            if (voskModelManager.ensureModel(language)) {
                voskModelManager.setActiveLanguage(language)
                // Restart wake-word listener with new model if enabled.
                meshService?.setWakeWordEnabled(false)
                meshService?.setWakeWordEnabled(_uiState.value.wakeWordEnabled)
                log("Switched wake-word language to $language", "INFO")
            } else {
                log("Model not available for $language. Starting download.", "WARN")
                downloadLanguage(language)
            }
        }
    }

    fun downloadLanguage(language: String) {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                _uiState.value = _uiState.value.copy(
                    modelDownloadLanguage = language,
                    modelDownloadProgress = 0f
                )
                voskModelManager.downloadAndActivateLanguage(language)
                log("Downloaded and activated wake-word language: $language", "INFO")
                // Restart listener to pick up the new model.
                meshService?.setWakeWordEnabled(false)
                meshService?.setWakeWordEnabled(_uiState.value.wakeWordEnabled)
            } catch (e: Exception) {
                log("Failed to download language $language: ${e.message}", "ERROR")
            }
        }
    }

    fun pruneInactiveModels(keepEnglish: Boolean) {
        viewModelScope.launch(Dispatchers.IO) {
            voskModelManager.pruneInactiveModels(keepEnglish = keepEnglish)
            refreshReadyLanguages()
            val msg = if (keepEnglish) "Pruned inactive wake-word models (kept English)" else "Pruned all inactive wake-word models including English"
            log(msg, "INFO")
        }
    }

    private fun startObservingVoskModelState() {
        viewModelScope.launch {
            voskModelManager.activeLanguage.collect { lang ->
                _uiState.value = _uiState.value.copy(wakeWordLanguage = lang)
            }
        }
        viewModelScope.launch {
            voskModelManager.downloadState.collect { state ->
                when (state) {
                    is VoskModelManager.DownloadState.Downloading -> {
                        _uiState.value = _uiState.value.copy(
                            modelDownloadLanguage = state.language,
                            modelDownloadProgress = state.progress
                        )
                    }
                    is VoskModelManager.DownloadState.Success -> {
                        _uiState.value = _uiState.value.copy(
                            modelDownloadLanguage = null,
                            modelDownloadProgress = null
                        )
                        refreshReadyLanguages()
                        if (pendingWakeWordEnableAfterDownload) {
                            pendingWakeWordEnableAfterDownload = false
                            setWakeWordEnabled(true)
                        } else {
                            _uiState.value = _uiState.value.copy(
                                wakeWordStatus = "Wake-word model ready"
                            )
                        }
                    }
                    is VoskModelManager.DownloadState.Error -> {
                        pendingWakeWordEnableAfterDownload = false
                        _uiState.value = _uiState.value.copy(
                            modelDownloadLanguage = null,
                            modelDownloadProgress = null,
                            wakeWordStatus = "Wake-word model download failed: ${state.reason}"
                        )
                    }
                    else -> { /* idle */ }
                }
            }
        }
    }

    private fun refreshReadyLanguages() {
        val codes = voskModelManager.availableLanguages.value
            .map { it.code }
            .filter { voskModelManager.isModelReady(it) }
            .toSet()
        _readyLanguages.value = codes
    }

    fun updateCommandInput(input: String) {
        _uiState.value = _uiState.value.copy(commandInput = input, voiceError = null, lastResult = null)
    }

    /**
     * Build a dynamic voice-command grammar from the system's actual knowledge:
     * - Learned commands (the user's real dialect)
     * - User-defined rules ("Teach Nexus")
     * - Built-in command keywords extracted from ZeroLLMCommandEngine patterns
     *
     * Never hardcodes phrases — adapts to how the user actually speaks.
     */
    suspend fun buildVoiceGrammar(): List<String> = withContext(Dispatchers.IO) {
        // 1. Learned commands — the user's real phrases that worked
        val learned = try {
            nexusApplication.learningRepository.getAllCommands().map { it.input }
        } catch (_: Exception) { emptyList() }

        // 2. User-defined rules — custom phrases the user taught Nexus
        val userRules = try {
            userRulesRepository.getEnabledRules().map { it.pattern }
        } catch (_: Exception) { emptyList() }

        // 3. Skills — downloadable command knowledge from the community repo
        val skillGrammar = try {
            nexusApplication.skillRegistry.getAllGrammar()
        } catch (_: Exception) { emptyList() }

        // 4. Built-in command keywords — minimal fallback, real knowledge comes from skills
        val builtinKeywords = ZeroLLMCommandEngine.extractCommandKeywords()

        // Merge all sources, deduplicate, lowercase
        (learned + userRules + skillGrammar + builtinKeywords)
            .map { it.trim().lowercase() }
            .filter { it.isNotBlank() }
            .distinct()
    }

    fun updateChatInput(input: String) {
        _uiState.value = _uiState.value.copy(chatInput = input)
    }

    // --- Skills System ---

    fun refreshSkills() {
        viewModelScope.launch(Dispatchers.IO) {
            _uiState.value = _uiState.value.copy(skillsLoading = true)
            try {
                val installed = nexusApplication.skillRegistry.getAllSkills()
                val available = try {
                    nexusApplication.skillRegistry.checkForUpdates().map { it.second }
                } catch (_: Exception) { emptyList() }
                _uiState.value = _uiState.value.copy(
                    installedSkills = installed,
                    availableSkills = available,
                    skillsLoading = false
                )
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(skillsLoading = false)
            }
        }
    }

    fun installSkill(manifest: SkillManifest) {
        viewModelScope.launch(Dispatchers.IO) {
            _uiState.value = _uiState.value.copy(skillsLoading = true)
            val success = nexusApplication.skillRegistry.installSkill(manifest)
            _uiState.value = _uiState.value.copy(skillsLoading = false)
            if (success) showSkillStatus("Installed ${manifest.name}")
            else showSkillStatus("Failed to install ${manifest.name}")
            refreshSkills()
        }
    }

    fun toggleSkill(skillId: String, enabled: Boolean) {
        nexusApplication.skillRegistry.setSkillEnabled(skillId, enabled)
        refreshSkills()
    }

    fun removeSkill(skillId: String) {
        nexusApplication.skillRegistry.removeSkill(skillId)
        refreshSkills()
    }

    fun updateSkill(skillId: String) {
        viewModelScope.launch(Dispatchers.IO) {
            val success = nexusApplication.skillRegistry.updateSkill(skillId)
            if (success) showSkillStatus("Updated skill")
            else showSkillStatus("Failed to update")
            refreshSkills()
        }
    }

    fun browseAvailableSkills() {
        viewModelScope.launch(Dispatchers.IO) {
            _uiState.value = _uiState.value.copy(skillsLoading = true)
            try {
                val downloader = com.nexus.app.skill.SkillDownloader(getApplication())
                val available = downloader.fetchAvailableSkills()
                _uiState.value = _uiState.value.copy(
                    availableSkills = available,
                    skillsLoading = false
                )
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(skillsLoading = false)
            }
        }
    }

    fun dismissSkillStatus() {
        _uiState.value = _uiState.value.copy(skillStatusMessage = null)
    }

    private fun showSkillStatus(message: String) {
        _uiState.value = _uiState.value.copy(skillStatusMessage = message)
        viewModelScope.launch {
            delay(4000)
            if (_uiState.value.skillStatusMessage == message) {
                _uiState.value = _uiState.value.copy(skillStatusMessage = null)
            }
        }
    }

    fun refreshChatBackend() {
        viewModelScope.launch(Dispatchers.IO) {
            val context = getApplication<NexusApplication>()
            chatBackend = LLMBackendDiscovery.bestBackend(context)
            val status = if (chatBackend == null) {
                "No local LLM server detected. Install Ollama or start llama.cpp/LM Studio."
            } else {
                "Using ${chatBackend?.backend?.name} with model ${chatBackend?.selectedModel ?: "unknown"}."
            }
            _uiState.value = _uiState.value.copy(chatBackendStatus = status)
        }
    }

    private fun loadChatHistory() {
        viewModelScope.launch(Dispatchers.IO) {
            val messages = nexusBrain.loadHistory()
            _uiState.value = _uiState.value.copy(chatMessages = messages)
        }
    }

    fun sendChatMessage() {
        val text = _uiState.value.chatInput.trim()
        if (text.isBlank()) return
        _uiState.value = _uiState.value.copy(chatInput = "", chatPendingConfirmation = false)
        viewModelScope.launch(Dispatchers.IO) {
            // Resource combining: if this device has no local LLM, offload the
            // chat to a paired node that runs one (e.g. the desktop brain).
            val response = if (chatBackend != null) {
                nexusBrain.chat(text, chatBackend)
            } else {
                relayChatToMeshNode(text) ?: nexusBrain.chat(text, null)
            }
            _uiState.value = _uiState.value.copy(
                chatMessages = nexusBrain.loadHistory(),
                chatPendingConfirmation = response.requiresConfirmation
            )
        }
    }

    private suspend fun relayChatToMeshNode(text: String): BrainResponse? {
        val nodes = _meshNodes.value.filter { it.transport == TransportType.WIFI_NSD }
        for (node in nodes) {
            if (!isPaired(node)) continue
            val reply = meshService?.chatWithNode(node, text) ?: continue
            if (reply.isNotBlank()) {
                log("Chat answered by ${node.name} over mesh.", "INFO")
                return nexusBrain.recordExternalTurn(text, reply)
            }
        }
        return null
    }

    fun confirmChatCommand() {
        viewModelScope.launch(Dispatchers.IO) {
            chatBackend?.let { backend ->
                val response = nexusBrain.confirmPendingCommand(backend)
                _uiState.value = _uiState.value.copy(
                    chatMessages = nexusBrain.loadHistory(),
                    chatPendingConfirmation = response.requiresConfirmation
                )
            }
        }
    }

    fun dismissChatConfirmation() {
        _uiState.value = _uiState.value.copy(chatPendingConfirmation = false)
    }

    fun setVoiceListening(listening: Boolean) {
        _uiState.value = _uiState.value.copy(
            isListening = listening,
            voiceError = null,
            voicePartialTranscript = "",
            voicePreparing = false
        )
    }

    fun setVoicePreparing(preparing: Boolean) {
        _uiState.value = _uiState.value.copy(voicePreparing = preparing)
    }

    /**
     * Returns a ready Vosk model for in-app voice input. When the user enabled
     * the high-accuracy English model, the larger -lgraph model is preferred;
     * otherwise the active language's model is used (downloaded on first use,
     * mirroring the wake-word path). Returns null if no model can be prepared.
     */
    suspend fun getVoiceModel(): org.vosk.Model? = withContext(Dispatchers.IO) {
        val lang = voskModelManager.getActiveLanguage()
        val useLarge = voskModelManager.isHighAccuracyVoiceEnabled() && lang == "en"
        val dir: String = if (useLarge) {
            if (!voskModelManager.isLargeEnglishModelReady()) {
                voskModelManager.ensureLargeEnglishModel()
            }
            if (!voskModelManager.isLargeEnglishModelReady()) return@withContext null
            voskModelManager.largeEnglishModelDirectory.absolutePath
        } else {
            var ready = voskModelManager.ensureModel(lang)
            if (!ready) {
                // Non-bundled languages aren't downloaded by ensureModel — use
                // the same model download the wake word relies on, but call the
                // manager directly: downloadLanguage() would restart the wake
                // listener, double-holding the mic while voice input runs.
                voskModelManager.downloadAndActivateLanguage(lang)
                repeat(120) {
                    if (voskModelManager.isModelReady(lang)) return@repeat
                    delay(1000)
                }
                ready = voskModelManager.isModelReady(lang)
            }
            if (!ready) return@withContext null
            voskModelManager.activeModelDirectory.absolutePath
        }
        // Reuse the cached model unless the directory changed (e.g. the user
        // toggled high-accuracy between sessions).
        if (voiceModel != null && voiceModelDir == dir) return@withContext voiceModel
        try {
            org.vosk.Model(dir).also {
                try { voiceModel?.close() } catch (_: Exception) { }
                voiceModel = it
                voiceModelDir = dir
            }
        } catch (e: Exception) {
            null
        }
    }

    /**
     * One-shot wake: when enabled, the wake-word listener keeps listening after
     * "hey nexus" and runs whatever command follows in the same utterance — no
     * overlay. The listener picks up the new mode on its next wake trigger, so
     * no service restart is required.
     */
    fun setOneShotWake(enabled: Boolean) {
        voskModelManager.setOneShotModeEnabled(enabled)
        _uiState.value = _uiState.value.copy(oneShotWake = enabled)
        log(if (enabled) "One-shot wake enabled" else "One-shot wake disabled", "INFO")
    }

    // --- Speaker Verification (Voice Enrollment) ---

    private var enrollmentSession: VoiceprintManager.EnrollmentSession? = null

    /**
     * Start the voice enrollment process. Records samples of the user saying
     * the wake phrase to create a voiceprint for speaker verification.
     */
    fun startVoiceEnrollment() {
        enrollmentSession = voiceprintManager.startEnrollment()
        _uiState.value = _uiState.value.copy(
            voiceEnrollmentState = VoiceEnrollmentState.Recording(
                sampleCount = 0,
                required = VoiceprintManager.REQUIRED_SAMPLES
            )
        )
        log("Voice enrollment started — say your wake phrase 3 times", "INFO")
    }

    /**
     * Start recording an enrollment sample. Must be called after startVoiceEnrollment.
     */
    fun startEnrollmentRecording() {
        val session = enrollmentSession ?: return
        if (!session.startRecording()) {
            _uiState.value = _uiState.value.copy(
                voiceEnrollmentState = VoiceEnrollmentState.Error("Could not start recording")
            )
            return
        }
        _uiState.value = _uiState.value.copy(
            voiceEnrollmentState = VoiceEnrollmentState.Recording(
                sampleCount = session.sampleCount,
                required = VoiceprintManager.REQUIRED_SAMPLES
            )
        )
    }

    /**
     * Stop recording and process the enrollment sample.
     */
    fun stopEnrollmentRecording() {
        val session = enrollmentSession ?: return
        viewModelScope.launch(Dispatchers.IO) {
            val result = session.stopRecording()
            when (result) {
                is VoiceprintManager.EnrollmentResult.SampleRecorded -> {
                    _uiState.value = _uiState.value.copy(
                        voiceEnrollmentState = VoiceEnrollmentState.SampleRecorded(
                            message = result.message,
                            sampleCount = session.sampleCount,
                            required = VoiceprintManager.REQUIRED_SAMPLES
                        )
                    )
                    log(result.message, "INFO")
                }
                is VoiceprintManager.EnrollmentResult.Success -> {
                    _uiState.value = _uiState.value.copy(
                        voiceEnrollmentState = VoiceEnrollmentState.Completed(result.message),
                        voiceprintEnrolled = true,
                        voiceprintVerificationEnabled = true
                    )
                    log(result.message, "INFO")
                }
                is VoiceprintManager.EnrollmentResult.Error -> {
                    _uiState.value = _uiState.value.copy(
                        voiceEnrollmentState = VoiceEnrollmentState.Error(result.message)
                    )
                    log("Enrollment error: ${result.message}", "ERROR")
                }
            }
        }
    }

    /**
     * Cancel the current enrollment session.
     */
    fun cancelVoiceEnrollment() {
        enrollmentSession?.cancel()
        enrollmentSession = null
        _uiState.value = _uiState.value.copy(
            voiceEnrollmentState = VoiceEnrollmentState.Idle
        )
        log("Voice enrollment cancelled", "INFO")
    }

    /**
     * Enable or disable speaker verification.
     */
    fun setSpeakerVerificationEnabled(enabled: Boolean) {
        voiceprintManager.setVerificationEnabled(enabled)
        _uiState.value = _uiState.value.copy(
            voiceprintVerificationEnabled = enabled
        )
        log(if (enabled) "Speaker verification enabled" else "Speaker verification disabled", "INFO")
    }

    /**
     * Set a custom wake phrase.
     */
    fun setCustomWakePhrase(phrase: String?) {
        voiceprintManager.setCustomWakePhrase(phrase)
        _uiState.value = _uiState.value.copy(
            customWakePhrase = phrase
        )
        log("Custom wake phrase set: ${phrase ?: "default"}", "INFO")
        // Restart the wake-word listener so the Vosk grammar picks up the new phrase.
        if (_uiState.value.wakeWordEnabled) {
            meshService?.setWakeWordEnabled(false)
            meshService?.setWakeWordEnabled(true)
        }
    }

    /**
     * Clear all voice enrollment data.
     */
    fun clearVoiceEnrollment() {
        voiceprintManager.clearEnrollment()
        _uiState.value = _uiState.value.copy(
            voiceprintEnrolled = false,
            voiceprintVerificationEnabled = false,
            voiceEnrollmentState = VoiceEnrollmentState.Idle
        )
        log("Voice enrollment cleared", "INFO")
    }

    /** Opts into the larger English voice model (downloads it in the background). */
    fun setHighAccuracyVoice(enabled: Boolean) {
        voskModelManager.setHighAccuracyVoiceEnabled(enabled)
        _uiState.value = _uiState.value.copy(
            highAccuracyVoice = enabled,
            highAccuracyVoiceReady = voskModelManager.isLargeEnglishModelReady()
        )
        log(if (enabled) "High-accuracy voice enabled" else "High-accuracy voice disabled", "INFO")
        if (enabled && !voskModelManager.isLargeEnglishModelReady()) {
            viewModelScope.launch(Dispatchers.IO) {
                voskModelManager.ensureLargeEnglishModel()
            }
        }
    }

    private fun startObservingLargeModelState() {
        viewModelScope.launch {
            voskModelManager.largeModelDownload.collect { state ->
                when (state) {
                    is VoskModelManager.DownloadState.Downloading -> {
                        _uiState.value = _uiState.value.copy(
                            highAccuracyVoiceDownloading = true,
                            highAccuracyVoiceProgress = state.progress
                        )
                    }
                    is VoskModelManager.DownloadState.Success -> {
                        _uiState.value = _uiState.value.copy(
                            highAccuracyVoiceDownloading = false,
                            highAccuracyVoiceProgress = null,
                            highAccuracyVoiceReady = true
                        )
                    }
                    is VoskModelManager.DownloadState.Error -> {
                        _uiState.value = _uiState.value.copy(
                            highAccuracyVoiceDownloading = false,
                            highAccuracyVoiceProgress = null
                        )
                    }
                    else -> Unit
                }
            }
        }
    }

    /** Temporarily pause the wake-word mic listener while in-app voice input
     *  holds the microphone (avoids double-AudioRecord conflicts). */
    fun pauseWakeWordForVoiceInput() {
        meshService?.pauseWakeWordListener()
    }

    /** Restart the wake-word listener once voice input is done. */
    fun resumeWakeWordAfterVoiceInput() {
        meshService?.resumeWakeWordListener()
    }

    fun setWakeWordEnabled(enabled: Boolean) {
        if (enabled) {
            val lang = voskModelManager.getActiveLanguage()
            if (!voskModelManager.isModelReady(lang)) {
                pendingWakeWordEnableAfterDownload = true
                _uiState.value = _uiState.value.copy(
                    wakeWordEnabled = false,
                    wakeWordStatus = "Downloading wake-word model…"
                )
                downloadLanguage(lang)
                log("Wake-word model missing; starting download for $lang", "INFO")
                return
            }
        }
        pendingWakeWordEnableAfterDownload = false
        _uiState.value = _uiState.value.copy(
            wakeWordEnabled = enabled,
            wakeWordStatus = if (enabled) "Wake word active — say \"hey nexus\"" else null
        )
        meshService?.setWakeWordEnabled(enabled)
    }

    fun requestWakeWordPermission() {
        val app = getApplication<NexusApplication>()
        if (ContextCompat.checkSelfPermission(app, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            setWakeWordEnabled(true)
            return
        }
        pendingWakeWordAfterPermission = true
        viewModelScope.launch {
            _permissionRequest.emit(arrayOf(Manifest.permission.RECORD_AUDIO))
        }
    }

    fun onWakeWordTriggered() {
        log("Wake-word trigger detected.", "INFO")
    }

    private fun observeWakeWordEvents() {
        wakeWordJob?.cancel()
        wakeWordJob = viewModelScope.launch {
            meshService?.wakeEvent?.collect {
                log("Wake word detected — starting voice input.", "INFO")
                _wakeWordEvent.tryEmit(Unit)
            }
        }
    }

    // --- Battery optimization (Doze) exemption ---
    // The wake-word listener is a foreground service, but aggressive OEM
    // battery managers can still kill it overnight. Requesting exemption keeps
    // the mic alive so "hey nexus" works in the morning too.

    /** True if the OS has exempted Nexus from battery optimization. */
    private fun isBatteryOptimizationExempt(): Boolean {
        val app = getApplication<NexusApplication>()
        val pm = app.getSystemService(Context.POWER_SERVICE) as? PowerManager
            ?: return false
        return pm.isIgnoringBatteryOptimizations(app.packageName)
    }

    /** Refresh the UI state with the current battery-optimization status. */
    fun refreshBatteryOptimizationStatus() {
        _uiState.value = _uiState.value.copy(
            batteryOptimizationExempt = isBatteryOptimizationExempt()
        )
    }

    /**
     * Opens the system dialog requesting exemption from battery optimization.
     * Requires REQUEST_IGNORE_BATTERY_OPTIMIZATIONS in the manifest.
     * Falls back to the app's battery/settings page if the dialog is
     * unavailable (e.g. some OEMs or the system refuses).
     */
    fun requestBatteryOptimizationExemption() {
        val app = getApplication<NexusApplication>()
        try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:${app.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (intent.resolveActivity(app.packageManager) != null) {
                app.startActivity(intent)
                return
            }
        } catch (_: Exception) { }
        // Fallback: app details settings (battery section) where the user can
        // toggle "Allow background activity" / "Unrestricted" manually.
        try {
            val fallback = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:${app.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            app.startActivity(fallback)
        } catch (_: Exception) { }
    }

    fun requestVoicePermission(target: VoiceTarget = VoiceTarget.COMMAND) {
        pendingVoiceAfterPermission = true
        pendingVoiceTarget = target
        viewModelScope.launch {
            _permissionRequest.emit(arrayOf(Manifest.permission.RECORD_AUDIO))
        }
    }

    fun onVoiceError(error: String) {
        _uiState.value = _uiState.value.copy(
            isListening = false,
            voiceError = error,
            voicePartialTranscript = "",
            voicePreparing = false
        )
        log("Voice error: $error", "ERROR")
        viewModelScope.launch {
            delay(4000)
            _uiState.value = _uiState.value.copy(voiceError = null)
        }
    }

    fun onVoiceCommandRecognized(command: String) {
        val cleaned = command.trim().replace("\\s+".toRegex(), " ")
        _uiState.value = _uiState.value.copy(
            isListening = false,
            commandInput = cleaned,
            voiceError = null,
            voicePartialTranscript = "",
            voicePreparing = false
        )
        runCommand()
    }

    fun onVoiceChatRecognized(command: String) {
        val cleaned = command.trim().replace("\\s+".toRegex(), " ")
        _uiState.value = _uiState.value.copy(
            isListening = false,
            chatInput = cleaned,
            voiceError = null,
            voicePartialTranscript = "",
            voicePreparing = false
        )
        sendChatMessage()
    }

    /** Live partial transcript from the on-device voice input. */
    fun onVoicePartialRecognized(text: String) {
        _uiState.value = _uiState.value.copy(voicePartialTranscript = text)
    }

    fun setLastPermissionRequest(permission: String) {
        _uiState.value = _uiState.value.copy(lastPermissionRequest = permission)
    }

    fun showPermissionRationale(permissions: Array<String>, message: String) {
        pendingPermissions = permissions
        _uiState.value = _uiState.value.copy(
            permissionRationale = PermissionRationale(permissions.firstOrNull() ?: "", message)
        )
    }

    fun onRationaleContinue() {
        val permissions = pendingPermissions ?: return
        pendingPermissions = null
        _uiState.value = _uiState.value.copy(permissionRationale = null)
        viewModelScope.launch {
            _permissionRequest.emit(permissions)
        }
    }

    fun dismissPermissionRationale() {
        pendingPermissions = null
        _uiState.value = _uiState.value.copy(permissionRationale = null)
    }

    fun runCommand() {
        val input = _uiState.value.commandInput
        if (input.isBlank()) return

        if (input.trim().equals("start mesh", ignoreCase = true)) {
            checkAndRequestMeshPermissions()
            return
        }

        val scan = securityGuard.scan(input)
        if (scan.rejected) {
            log("Security guard rejected input: ${scan.reason}", "WARN")
            _uiState.value = _uiState.value.copy(
                lastResult = CommandResult(false, scan.reason, com.nexus.app.command.CommandAction.Rejected(scan.reason))
            )
            return
        }

        val commandString = scan.commandString
        viewModelScope.launch {
            log("Processing: $commandString", "INFO")

            // 1. Try adaptive resolution first (patterns + context learned from usage)
            val adaptiveResult = try {
                adaptiveEngine.tryAdaptiveResolve(commandString)
            } catch (_: Exception) { null }

            // 2. Fall back to rule engine if adaptive isn't confident enough
            val result = if (adaptiveResult != null && adaptiveResult.confidence >= 0.6f) {
                // Adaptive engine is confident — execute its resolution directly
                log("Adaptive resolve [${adaptiveResult.method}]: ${adaptiveResult.actionType}", "INFO")
                val action = ZeroLLMCommandEngine.parseCommand(commandString)
                    ?: com.nexus.app.command.CommandAction.Unknown(commandString)
                val execResult = commandEngine.performAction(
                    resolveActionFromAdaptive(adaptiveResult, commandString)
                )
                // Record success for learning
                adaptiveEngine.recordSuccess(
                    commandString, adaptiveResult.actionType, adaptiveResult.payload,
                    adaptiveResult.confidence, adaptiveResult.method
                )
                execResult
            } else {
                // Rule engine handles it
                commandEngine.executeCommand(commandString)
            }

            handleCommandResult(result)
            if (result.success || result.shouldRecordForRoutines) {
                routineRepository.recordCommand(commandString, result.action)
                // Record success in adaptive engine for pattern learning
                adaptiveEngine.recordSuccess(
                    commandString,
                    result.action.name,
                    resolutionMethod = if (adaptiveResult != null) adaptiveResult.method else "RULE"
                )
                refreshRoutines()
            } else {
                // Record failure so patterns with low confidence get penalized
                adaptiveEngine.recordFailure(commandString)
            }
            _uiState.value = _uiState.value.copy(lastResult = result, commandInput = "")
        }
    }

    /**
     * Resolve a CommandAction from an adaptive engine result.
     * Maps the adaptive resolution back to a concrete CommandAction the
     * command engine can execute.
     */
    private fun resolveActionFromAdaptive(
        adaptive: AdaptiveEngine.AdaptiveResult,
        originalInput: String
    ): com.nexus.app.command.CommandAction {
        return when (adaptive.actionType) {
            "PLAY_MEDIA" -> com.nexus.app.command.CommandAction.PlayMedia(adaptive.payload)
            "PLAY_MEDIA_APP" -> {
                val parts = adaptive.payload.split("|", limit = 2)
                com.nexus.app.command.CommandAction.PlayMediaApp(
                    parts.getOrNull(0) ?: adaptive.payload,
                    parts.getOrNull(1) ?: ""
                )
            }
            "OPEN_APP" -> com.nexus.app.command.CommandAction.OpenApp(adaptive.payload)
            "NAVIGATE" -> {
                val parts = adaptive.payload.split("|", limit = 2)
                com.nexus.app.command.CommandAction.Navigate(
                    parts[0], parts.getOrNull(1)?.takeIf { it.isNotBlank() }
                )
            }
            "SET_ALARM" -> {
                val parts = adaptive.payload.split(":")
                com.nexus.app.command.CommandAction.SetAlarm(
                    parts.getOrNull(0)?.toIntOrNull() ?: 7,
                    parts.getOrNull(1)?.toIntOrNull() ?: 0
                )
            }
            "SET_TIMER" -> com.nexus.app.command.CommandAction.SetTimer(adaptive.payload.toIntOrNull() ?: 60)
            "MESH_RELAY" -> com.nexus.app.command.CommandAction.MeshRelay(adaptive.payload)
            "MUTE_VOLUME" -> com.nexus.app.command.CommandAction.MuteVolume()
            "PAUSE_MEDIA" -> com.nexus.app.command.CommandAction.PauseMedia("")
            "MEDIA_CONTROL" -> com.nexus.app.command.CommandAction.MediaControl(adaptive.payload)
            "TOGGLE_FLASHLIGHT" -> com.nexus.app.command.CommandAction.ToggleFlashlight(adaptive.payload.toBooleanStrictOrNull() ?: true)
            "TOGGLE_WIFI" -> com.nexus.app.command.CommandAction.ToggleWifi(adaptive.payload.toBooleanStrictOrNull() ?: true)
            "TOGGLE_BLUETOOTH" -> com.nexus.app.command.CommandAction.ToggleBluetooth(adaptive.payload.toBooleanStrictOrNull() ?: true)
            "GET_TIME_DATE" -> com.nexus.app.command.CommandAction.GetTimeDate()
            "GET_WEATHER" -> com.nexus.app.command.CommandAction.GetWeather()
            "GET_BATTERY_STATUS" -> com.nexus.app.command.CommandAction.GetBatteryStatus()
            "GET_JOKE" -> com.nexus.app.command.CommandAction.GetJoke()
            "OPEN_CALENDAR" -> com.nexus.app.command.CommandAction.OpenCalendar()
            "OPEN_SETTINGS" -> com.nexus.app.command.CommandAction.OpenSettings("android.settings.SETTINGS")
            // Fallback: let the rule engine parse the original input
            else -> ZeroLLMCommandEngine.parseCommand(originalInput)
                ?: com.nexus.app.command.CommandAction.Unknown(originalInput)
        }
    }

    private fun checkAndRequestMeshPermissions() {
        val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        val app = getApplication<NexusApplication>()
        val allGranted = permissions.all {
            ContextCompat.checkSelfPermission(app, it) == PackageManager.PERMISSION_GRANTED
        }
        if (allGranted) {
            log("Mesh permissions already granted. Starting service.", "INFO")
            startMeshService()
        } else {
            _uiState.value = _uiState.value.copy(
                internState = InternProtocolState.Visible(
                    title = "Find nearby devices",
                    message = "Nexus needs Bluetooth and location permissions to discover nearby devices.",
                    choices = listOf("Grant Mesh Permissions", "Cancel"),
                    onChoice = { onInternChoice(it) }
                )
            )
        }
    }

    fun onMeshPermissionsResult(granted: Boolean) {
        if (granted) {
            log("Mesh permissions granted. Starting service.", "INFO")
            startMeshService()
        } else {
            log("Mesh permissions denied. Mesh networking unavailable.", "WARN")
        }
    }

    fun onInternChoice(choice: String) {
        log("Intern protocol choice: $choice", "INFO")
        _uiState.value = _uiState.value.copy(internState = InternProtocolState.Hidden)
        viewModelScope.launch {
            val app = getApplication<NexusApplication>()
            when (choice) {
                "Open Settings" -> {
                    val settingsIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.parse("package:${app.packageName}")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    settingsIntent.resolveActivity(app.packageManager)?.let {
                        app.startActivity(settingsIntent)
                    }
                }
                "Grant Permission" -> {
                    val appDetailsIntent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                        data = Uri.parse("package:${app.packageName}")
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    appDetailsIntent.resolveActivity(app.packageManager)?.let {
                        app.startActivity(appDetailsIntent)
                    }
                }
                "Grant DND Permission" -> {
                    val intent = Intent(Settings.ACTION_NOTIFICATION_POLICY_ACCESS_SETTINGS).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    getApplication<NexusApplication>().startActivity(intent)
                }
                "Grant Location Permission" -> {
                    pendingCommandAfterPermission = _uiState.value.commandInput
                    _permissionRequest.emit(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION))
                }
                "Grant Calendar Permission" -> {
                    pendingCommandAfterPermission = _uiState.value.commandInput
                    _permissionRequest.emit(arrayOf(Manifest.permission.READ_CALENDAR))
                }
                "Grant Bluetooth Permission" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        pendingCommandAfterPermission = _uiState.value.commandInput
                        _permissionRequest.emit(arrayOf(Manifest.permission.BLUETOOTH_CONNECT))
                    }
                }
                "Grant Mesh Permissions" -> {
                    val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        arrayOf(
                            Manifest.permission.BLUETOOTH_CONNECT,
                            Manifest.permission.BLUETOOTH_SCAN,
                            Manifest.permission.BLUETOOTH_ADVERTISE
                        )
                    } else {
                        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
                    }
                    pendingCommandAfterPermission = "start mesh"
                    _permissionRequest.emit(permissions)
                }
                "Retry" -> {
                    runCommand()
                }
                "Cancel", "Not now" -> {
                    lastUnknownCommand = null
                    log("Intern protocol dismissed.", "INFO")
                }
                "Teach Nexus" -> {
                    showRuleEditor(true, lastUnknownCommand)
                    lastUnknownCommand = null
                }
            }
        }
    }

    fun onPermissionResult(granted: Boolean) {
        if (granted) {
            log("Permissions granted.", "INFO")
            if (pendingVoiceAfterPermission) {
                pendingVoiceAfterPermission = false
                viewModelScope.launch {
                    _voicePermissionResult.emit(true)
                }
            }
            if (pendingWakeWordAfterPermission) {
                pendingWakeWordAfterPermission = false
                setWakeWordEnabled(true)
            }
            pendingCommandAfterPermission?.let { command ->
                pendingCommandAfterPermission = null
                updateCommandInput(command)
                runCommand()
            } ?: log("Permissions granted; retry the command.", "INFO")
        } else {
            if (pendingVoiceAfterPermission) {
                pendingVoiceAfterPermission = false
                viewModelScope.launch {
                    _voicePermissionResult.emit(false)
                }
            }
            if (pendingWakeWordAfterPermission) {
                pendingWakeWordAfterPermission = false
                _uiState.value = _uiState.value.copy(wakeWordEnabled = false)
            }
            log("Permissions denied.", "WARN")
        }
    }

    fun clearLogs() {
        viewModelScope.launch(Dispatchers.IO) {
            database.memoryLogDao().clearAll()
        }
    }

    fun addUserRule(pattern: String, actionType: String, payload: String) {
        val rule = UserDialectRule.createNew(pattern, actionType, payload)
        viewModelScope.launch {
            val success = userRulesRepository.addRule(rule)
            if (success) {
                log("Added user rule: ${rule.pattern} -> ${rule.actionType}", "INFO")
            } else {
                log("Failed to add user rule.", "ERROR")
            }
        }
    }

    private var lastUnknownCommand: String? = null

    fun showRuleEditor(show: Boolean, prefilledPattern: String? = null) {
        _uiState.value = _uiState.value.copy(showRuleEditor = show, ruleEditorPrefill = prefilledPattern ?: "")
    }

    private fun refreshHardwareProfile() {
        _uiState.value = _uiState.value.copy(
            executionMode = hardwareManager.determineExecutionMode(),
            availableRamMb = hardwareManager.availableRamMb,
            totalRamMb = hardwareManager.totalRamMb
        )
    }

    private fun startObservingLogs() {
        viewModelScope.launch(Dispatchers.IO) {
            database.memoryLogDao().getRecentLogs(200).collectLatest { logs ->
                val formatted = logs.map { "[${it.level}] ${formatTime(it.timestamp)} ${it.message}" }
                _uiState.value = _uiState.value.copy(logs = formatted)
            }
        }
    }

    private fun startObservingRules() {
        viewModelScope.launch(Dispatchers.IO) {
            userRulesRepository.getEnabledRulesFlow().collectLatest { rules ->
                _uiState.value = _uiState.value.copy(rules = rules)
            }
        }
    }

    private fun handleCommandResult(result: CommandResult) {
        if (result.success) {
            log("OK: ${result.message}", "INFO")
        } else {
            log("FAIL: ${result.message}", "ERROR")
        }
        if (result.requiresInternChoice && result.choices.isNotEmpty()) {
            lastUnknownCommand = (result.action as? com.nexus.app.command.CommandAction.Unknown)?.raw
            _uiState.value = _uiState.value.copy(
                internState = InternProtocolState.Visible(
                    title = "What should Nexus do?",
                    message = result.message,
                    choices = result.choices,
                    onChoice = { onInternChoice(it) }
                )
            )
        }
    }

    fun log(message: String, level: String = "INFO") {
        viewModelScope.launch(Dispatchers.IO) {
            database.memoryLogDao().insert(MemoryLogEntity(message = message, level = level))
        }
    }

    fun dismissRoutineSuggestion(suggestion: RoutineSuggestion) {
        viewModelScope.launch(Dispatchers.IO) {
            routineRepository.dismiss(suggestion)
        }
    }

    fun refreshRoutines() {
        viewModelScope.launch(Dispatchers.IO) {
            routineRepository.refreshRoutines()
        }
    }

    private fun startObservingRoutineSuggestions() {
        viewModelScope.launch {
            routineRepository.activeSuggestions().collectLatest { suggestions ->
                _uiState.value = _uiState.value.copy(routineSuggestions = suggestions)
            }
        }
    }

    fun startMeshService() {
        val app = getApplication() as NexusApplication
        val intent = Intent(app, NexusMeshService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            app.startForegroundService(intent)
        } else {
            app.startService(intent)
        }
    }

    fun bindMeshService() {
        val app = getApplication() as NexusApplication
        val intent = Intent(app, NexusMeshService::class.java)
        synchronized(bindingLock) {
            serviceBindingCount++
            if (serviceBindingCount == 1) {
                app.bindService(intent, meshServiceConnection, Context.BIND_AUTO_CREATE)
                serviceBound = true
            }
        }
    }

    fun unbindMeshService() {
        val app = getApplication() as NexusApplication
        synchronized(bindingLock) {
            if (serviceBindingCount > 0) {
                serviceBindingCount--
                if (serviceBindingCount == 0 && serviceBound) {
                    app.unbindService(meshServiceConnection)
                    serviceBound = false
                    meshService = null
                }
            }
        }
    }

    private fun observeMeshNodes() {
        viewModelScope.launch {
            meshService?.discoveredNodes?.collect { nodes ->
                _meshNodes.value = nodes.values.toList().sortedByDescending { it.lastSeen }
                // Auto-pair any newly discovered node while hosting a QR pairing code.
                activeQrPin?.let { pin ->
                    nodes.values.forEach { node ->
                        if (!isPaired(node)) {
                            meshService?.pairWithNode(node.id, pin)
                        }
                    }
                }
            }
        }
    }

    fun relayToNode(node: MeshNode, command: String): Boolean {
        return meshService?.relayCommand(node, command) ?: false
    }

    fun pairWithNode(node: MeshNode, pin: String): Boolean {
        return meshService?.pairWithNode(node.id, pin) ?: false
    }

    fun pairWithNodeById(nodeId: String, pin: String): Boolean {
        return meshService?.pairWithNode(nodeId, pin) ?: false
    }

    fun getNodeId(): String = meshService?.nodeId ?: ""

    fun getNodeName(): String = meshService?.nodeName ?: "Nexus"

    /** Start hosting a QR pairing code. While [pin] is active, newly discovered
     *  nodes will be paired automatically using the same PIN. */
    fun startQrPairingHost(pin: String) {
        activeQrPin = pin
    }

    fun stopQrPairingHost() {
        activeQrPin = null
    }

    fun unpairNode(node: MeshNode) {
        meshService?.unpairNode(node.id)
    }

    fun isPaired(node: MeshNode): Boolean {
        return meshService?.isPaired(node.id) ?: false
    }

    fun playSoundPin(pin: String) {
        viewModelScope.launch(Dispatchers.IO) {
            soundPairingManager.playPin(pin)
        }
    }

    fun listenForSoundPin(timeoutMs: Int = 10000, minLength: Int = 4): String? {
        return soundPairingManager.listenForPin(timeoutMs, minLength)
    }

    private fun formatTime(timestamp: Long): String {
        val sdf = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault())
        return sdf.format(java.util.Date(timestamp))
    }
}
