package com.nexus.app.ui.viewmodel

import android.graphics.Bitmap
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
    val voicePartialTranscript: String = "",
    val voicePreparing: Boolean = false,
    val highAccuracyVoice: Boolean = false,
    val highAccuracyVoiceDownloading: Boolean = false,
    val highAccuracyVoiceProgress: Float? = null,
    val highAccuracyVoiceReady: Boolean = false,
    val oneShotWake: Boolean = false,
    val wakeWordEnabled: Boolean = false,
    val wakeWordLanguage: String = "en",
    val wakeWordStatus: String? = null,
    val voiceprintEnrolled: Boolean = false,
    val voiceprintVerificationEnabled: Boolean = false,
    val voiceEnrollmentState: VoiceEnrollmentState = VoiceEnrollmentState.Idle,
    val customWakePhrase: String? = null,
    val ambientNoiseLevel: Float = 0f,
    val ambientNoiseClassification: String = "Quiet",
    val batteryOptimizationExempt: Boolean = false,
    val modelDownloadProgress: Float? = null,
    val modelDownloadLanguage: String? = null,
    val routineSuggestions: List<RoutineSuggestion> = emptyList(),
    val ruleEditorPrefill: String = "",
    val chatMessages: List<ChatMessage> = emptyList(),
    val chatInput: String = "",
    val chatBackendStatus: String = "Checking local LLM…",
    val chatPendingConfirmation: Boolean = false,
    val installedSkills: List<InstalledSkill> = emptyList(),
    val availableSkills: List<SkillManifest> = emptyList(),
    val skillsLoading: Boolean = false,
    val skillStatusMessage: String? = null,
    // ── Server connection / Vision / MQTT ─────────────────────
    val serverUrl: String = "",
    val serverConnected: Boolean = false,
    val visionStatus: String = "Not connected",
    val cameraIds: List<String> = listOf("local-0"),
    val selectedCameraId: String = "local-0",
    val previewFps: Int = 5,
    val isPreviewRunning: Boolean = false,
    val previewBitmap: Bitmap? = null,
    val detectionsText: String = "",
    val visionResultText: String = "",
    val visionResultColor: Long = 0xFFAEAEB2,  // Gray300
    val mqttAvailable: Boolean = false,
    val mqttConnected: Boolean = false,
    val mqttBroker: String = "",
    val mqttPort: Int = 1883,
    val networkDeviceCount: Int = 0,
    val networkGpuCount: Int = 0,
    val networkCameraCount: Int = 0,
    val serverNodeId: String = ""
) {
    val canRunCommand: Boolean
        get() = commandInput.isNotBlank()
}
