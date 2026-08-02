package com.nexus.app.ui.viewmodel

import com.nexus.app.brain.ChatMessage
import com.nexus.app.command.CommandResult
import com.nexus.app.command.RoutineSuggestion
import com.nexus.app.command.UserDialectRule
import com.nexus.app.hardware.ExecutionMode
import com.nexus.app.skill.SkillManifest
import com.nexus.app.skill.InstalledSkill

sealed class InternProtocolState {
    data object Hidden : InternProtocolState()
    data class Visible(
        val title: String,
        val message: String,
        val choices: List<String>,
        val onChoice: (String) -> Unit
    ) : InternProtocolState()
}

data class PermissionRationale(
    val permission: String,
    val message: String
)

sealed class VoiceEnrollmentState {
    data object Idle : VoiceEnrollmentState()
    data class Recording(val sampleCount: Int, val required: Int) : VoiceEnrollmentState()
    data class SampleRecorded(val message: String, val sampleCount: Int, val required: Int) : VoiceEnrollmentState()
    data class Completed(val message: String) : VoiceEnrollmentState()
    data class Error(val message: String) : VoiceEnrollmentState()
}

data class NexusUiState(
    val executionMode: ExecutionMode = ExecutionMode.STANDARD_EDGE,
    val availableRamMb: Long = 0,
    val totalRamMb: Long = 0,
    val commandInput: String = "",
    val logs: List<String> = emptyList(),
    val lastResult: CommandResult? = null,
    val internState: InternProtocolState = InternProtocolState.Hidden,
    val rules: List<UserDialectRule> = emptyList(),
    val showRuleEditor: Boolean = false,
    val lastPermissionRequest: String? = null,
    val permissionRationale: PermissionRationale? = null,
    val isListening: Boolean = false,
    val voiceError: String? = null,
    // In-app (on-device Vosk) voice input state — live transcript + preparing flag.
    val voicePartialTranscript: String = "",
    val voicePreparing: Boolean = false,
    // Opt-in larger English voice model for fewer mishearings.
    val highAccuracyVoice: Boolean = false,
    val highAccuracyVoiceDownloading: Boolean = false,
    val highAccuracyVoiceProgress: Float? = null,
    val highAccuracyVoiceReady: Boolean = false,
    // One-shot wake: "hey nexus play my flow" runs in a single utterance.
    val oneShotWake: Boolean = false,
    val wakeWordEnabled: Boolean = false,
    val wakeWordLanguage: String = "en",
    val wakeWordStatus: String? = null,
    // Speaker verification state
    val voiceprintEnrolled: Boolean = false,
    val voiceprintVerificationEnabled: Boolean = false,
    val voiceEnrollmentState: VoiceEnrollmentState = VoiceEnrollmentState.Idle,
    val customWakePhrase: String? = null,
    val ambientNoiseLevel: Float = 0f,
    val ambientNoiseClassification: String = "Quiet",
    // Whether the OS has exempted Nexus from battery optimization (Doze), so
    // the wake-word listener can stay alive overnight.
    val batteryOptimizationExempt: Boolean = false,
    val modelDownloadProgress: Float? = null,
    val modelDownloadLanguage: String? = null,
    val routineSuggestions: List<RoutineSuggestion> = emptyList(),
    val ruleEditorPrefill: String = "",
    val chatMessages: List<ChatMessage> = emptyList(),
    val chatInput: String = "",
    val chatBackendStatus: String = "Checking local LLM…",
    val chatPendingConfirmation: Boolean = false,
    // Skills system
    val installedSkills: List<InstalledSkill> = emptyList(),
    val availableSkills: List<SkillManifest> = emptyList(),
    val skillsLoading: Boolean = false,
    val skillStatusMessage: String? = null
) {
    val canRunCommand: Boolean
        get() = commandInput.isNotBlank()
}
