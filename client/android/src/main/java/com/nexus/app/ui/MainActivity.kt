package com.nexus.app.ui

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import androidx.annotation.StringRes
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
import androidx.lifecycle.lifecycleScope
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.filled.Camera
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Message
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.RecordVoiceOver
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.IconButtonDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import com.nexus.app.R
import com.nexus.app.brain.ChatMessage
import com.nexus.app.command.CommandResult
import com.nexus.app.command.CommandStatus
import com.nexus.app.command.RoutineSuggestion
import com.nexus.app.hardware.ExecutionMode
import com.nexus.app.mesh.MeshNode
import com.nexus.app.service.NexusMeshService
import com.nexus.app.ui.components.HelpDialog
import com.nexus.app.ui.components.InternDialog
import com.nexus.app.ui.components.VoiceInputOverlay
import com.nexus.app.ui.components.VoiceEnrollmentDialog
import com.nexus.app.ui.components.RuleEditorDialog
import com.nexus.app.ui.components.DotGridVisualizer
import com.nexus.app.ui.components.VisionTab
import com.nexus.app.ui.theme.NexusAmber
import com.nexus.app.ui.theme.NexusBackground
import com.nexus.app.ui.theme.NexusCardDark
import com.nexus.app.ui.theme.NexusCardLight
import com.nexus.app.ui.theme.NexusGreen
import com.nexus.app.ui.theme.NexusNavBar
import com.nexus.app.ui.theme.NexusPurple
import com.nexus.app.ui.theme.NexusRed
import com.nexus.app.ui.theme.NexusSurfaceVariant
import com.nexus.app.ui.theme.NexusTeal
import com.nexus.app.ui.theme.NexusTheme
import com.nexus.app.ui.theme.White
import com.nexus.app.ui.viewmodel.InternProtocolState
import com.nexus.app.ui.viewmodel.NexusUiState
import com.nexus.app.ui.viewmodel.NexusViewModel
import com.nexus.app.ui.viewmodel.VoiceTarget
import com.nexus.app.voice.VoskModelManager
import com.nexus.app.voice.VoskVoiceInput
import kotlinx.coroutines.launch
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin
import kotlin.random.Random

class MainActivity : ComponentActivity() {

    /**
     * Min gap between wake-intent deliveries (ms). The wake-word service can
     * deliver BOTH a direct activity launch and a full-screen-intent
     * notification within the same trigger; this dedupes the duplicate so
     * voice input doesn't open twice.
     */
    private companion object {
        const val WAKE_VOICE_INPUT_DEDUPE_MS = 1_500L
    }

    private val viewModel: NexusViewModel by viewModels()

    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        val allGranted = permissions.entries.all { it.value }
        viewModel.onPermissionResult(allGranted)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        viewModel.bindMeshService()
        viewModel.startMeshService()

        // The wake-word listener can launch us directly (even from outside the
        // app, or over the lock screen) with a flag telling us to start voice
        // input immediately — or, in one-shot mode, with a command that was
        // already captured after the wake word ("hey nexus play my flow" →
        // "play my flow") that we should run without the overlay.
        pendingWakeWordVoiceInput = intent?.getBooleanExtra(
            NexusMeshService.EXTRA_WAKE_WORD_VOICE_INPUT, false
        ) == true
        pendingOneShotCommand = intent?.getStringExtra(
            NexusMeshService.EXTRA_WAKE_WORD_ONE_SHOT_COMMAND
        )?.takeIf { it.isNotBlank() }
        if (pendingWakeWordVoiceInput || pendingOneShotCommand != null) {
            prepareWakeScreen()
        }

        // Connect to Nexus server if running on same network
        // Default: emulator (10.0.2.2 → host) or physical device (check intent extra)
        val serverUrl = intent?.getStringExtra("nexus_server_url")
            ?: "http://10.0.2.2:9090"
        viewModel.setServerUrl(serverUrl)

        setContent {
            NexusTheme {
                NexusMainScreen(viewModel = viewModel)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val oneShotCommand = intent.getStringExtra(NexusMeshService.EXTRA_WAKE_WORD_ONE_SHOT_COMMAND)
        val voiceInputRequested = intent.getBooleanExtra(NexusMeshService.EXTRA_WAKE_WORD_VOICE_INPUT, false)
        if (!oneShotCommand.isNullOrBlank() || voiceInputRequested) {
            prepareWakeScreen()
            // A full-screen intent and a direct launch can both deliver this
            // intent within milliseconds, so dedupe within a short window.
            val now = SystemClock.elapsedRealtime()
            if (now - lastWakeVoiceInputMs < WAKE_VOICE_INPUT_DEDUPE_MS) return
            lastWakeVoiceInputMs = now
            // If the activity is already resumed (wake fired while the app was
            // in the foreground), onResume won't fire again — act right away.
            // Otherwise defer to onResume so we don't race the lifecycle.
            if (isResumed) {
                if (!oneShotCommand.isNullOrBlank()) {
                    runOneShotCommand(oneShotCommand)
                } else {
                    startVoiceInput()
                }
            } else {
                if (!oneShotCommand.isNullOrBlank()) {
                    pendingOneShotCommand = oneShotCommand
                } else {
                    pendingWakeWordVoiceInput = true
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        isResumed = true
        // Refresh battery-optimization status whenever the screen returns — the
        // user may have just toggled "Unrestricted" in the system dialog/settings.
        viewModel.refreshBatteryOptimizationStatus()
        pendingOneShotCommand?.let { command ->
            pendingOneShotCommand = null
            runOneShotCommand(command)
        }
        if (pendingWakeWordVoiceInput) {
            pendingWakeWordVoiceInput = false
            startVoiceInput()
        }
    }

    override fun onPause() {
        super.onPause()
        isResumed = false
    }

    override fun onDestroy() {
        super.onDestroy()
        cancelVoiceInput()
        viewModel.unbindMeshService()
    }

    /** Set when the wake-word listener launches us to start voice input. */
    private var pendingWakeWordVoiceInput = false

    /**
     * Set when the wake-word listener captured a one-shot command (wake word +
     * command in one utterance) and launched us to run it directly — no overlay.
     */
    private var pendingOneShotCommand: String? = null

    /** Tracks whether the activity is currently resumed (used by onNewIntent). */
    private var isResumed = false

    /** Last time a wake intent triggered voice input (dedupes double intents). */
    private var lastWakeVoiceInputMs = 0L

    /** The active in-app Vosk voice session (null when not listening). */
    private var voiceInput: VoskVoiceInput? = null

    /**
     * Monotonic session id for in-app voice input. Bumped on every new start
     * and on cancel; the model-preparation coroutine checks it after loading so
     * a cancel (or a fresh tap) during the load window can't silently start
     * listening in the background.
     */
    @Volatile
    private var voiceInputSession = 0L

    /**
     * Allows this activity to show over the lock screen and turns the screen
     * on when the wake word opens it. Uses the modern Activity APIs on API 27+
     * and falls back to the classic window flags on older versions.
     */
    private fun prepareWakeScreen() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                android.view.WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    android.view.WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
    }

    /**
     * Starts IN-APP voice input powered by the bundled Vosk engine — 100% on
     * the device, with no Google or cloud recognizer. A full-screen overlay
     * shows the live transcript and a stop button; the final text is routed to
     * the command (or chat) pipeline exactly like the old system dialog, minus
     * the privacy leak.
     */
    private fun startVoiceInput(target: VoiceTarget = VoiceTarget.COMMAND) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            viewModel.requestVoicePermission(target)
            return
        }
        if (voiceInput != null) return // already listening
        val session = ++voiceInputSession
        viewModel.setPendingVoiceTarget(target)
        viewModel.setVoiceListening(true)
        viewModel.setVoicePreparing(true)
        viewModel.pauseWakeWordForVoiceInput()
        lifecycleScope.launch {
            val model = viewModel.getVoiceModel()
            if (model == null) {
                viewModel.resumeWakeWordAfterVoiceInput()
                if (session == voiceInputSession) {
                    viewModel.onVoiceError(getString(R.string.voice_model_unavailable))
                }
                return@launch
            }
            // The user cancelled (or started a new session) while the model was
            // loading — never start listening in the background.
            if (session != voiceInputSession) {
                viewModel.resumeWakeWordAfterVoiceInput()
                return@launch
            }
            // `thisInput` is captured so the terminal callbacks can null the
            // session reference without clobbering a newer session's instance
            // (silent-timeout/error paths must not leave the mic blocked).
            var thisInput: VoskVoiceInput? = null
            // Use grammar-constrained recognition for commands (eliminates
            // phantom words), free-form for chat. The grammar is built dynamically
            // from the user's learned commands, custom rules, and built-in patterns.
            val cmdGrammar = if (target == VoiceTarget.COMMAND) {
                try { viewModel.buildVoiceGrammar() } catch (e: kotlinx.coroutines.CancellationException) { throw e } catch (_: Exception) { null }
            } else null
            val input = VoskVoiceInput(
                onPartial = viewModel::onVoicePartialRecognized,
                onFinal = { text -> handleVoiceResult(target, text) },
                onCancelled = {
                    if (voiceInput === thisInput) voiceInput = null
                    viewModel.resumeWakeWordAfterVoiceInput()
                    viewModel.setVoiceListening(false)
                },
                onError = { message ->
                    if (voiceInput === thisInput) voiceInput = null
                    viewModel.resumeWakeWordAfterVoiceInput()
                    viewModel.onVoiceError(message)
                },
                grammar = cmdGrammar
            )
            thisInput = input
            voiceInput = input
            viewModel.setVoicePreparing(false)
            input.start(model)
        }
    }

    /** Routes recognized speech to the command/chat pipeline and releases the mic. */
    private fun handleVoiceResult(target: VoiceTarget, text: String) {
        voiceInput = null
        viewModel.resumeWakeWordAfterVoiceInput()
        when (target) {
            VoiceTarget.COMMAND -> viewModel.onVoiceCommandRecognized(text)
            VoiceTarget.CHAT -> viewModel.onVoiceChatRecognized(text)
        }
    }

    /**
     * Runs a command captured by the one-shot wake listener directly through the
     * normal command pipeline — no voice-input overlay. Logs to the same place
     * as typed commands so the result shows up on the Home tab.
     */
    private fun runOneShotCommand(command: String) {
        viewModel.updateCommandInput(command)
        viewModel.runCommand()
    }

    /** Stop listening and submit the best transcript captured so far. */
    private fun stopVoiceInput() {
        voiceInput?.stop()
    }

    /** Cancel listening and discard the transcript. */
    private fun cancelVoiceInput() {
        voiceInputSession++ // invalidate any in-flight model preparation
        voiceInput?.cancel()
        voiceInput = null
        viewModel.resumeWakeWordAfterVoiceInput()
        viewModel.setVoiceListening(false)
    }

    private fun startVoiceChat() {
        startVoiceInput(VoiceTarget.CHAT)
    }

    fun requestRecordAudioPermission() {
        permissionLauncher.launch(arrayOf(Manifest.permission.RECORD_AUDIO))
    }

    @Suppress("DEPRECATION")
    private enum class NexusTab(@StringRes val labelRes: Int, val icon: ImageVector) {
        HOME(R.string.tab_home, Icons.Default.Home),
        CHAT(R.string.tab_chat, Icons.Default.Message),
        TALK(R.string.tab_talk, Icons.Default.RecordVoiceOver),
        VISION(R.string.tab_vision, Icons.Default.Camera),
        LOGS(R.string.tab_logs, Icons.Default.List),
        SETTINGS(R.string.tab_settings, Icons.Default.Settings)
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable
    fun NexusMainScreen(viewModel: NexusViewModel) {
        val state = viewModel.uiState.collectAsState().value
        var selectedTab by rememberSaveable { mutableStateOf(NexusTab.HOME) }
        var showHelp by rememberSaveable { mutableStateOf(false) }

        if (showHelp) {
            HelpDialog(onDismiss = { showHelp = false })
        }

        LaunchedEffect(Unit) {
            viewModel.permissionRequest.collect { permissions ->
                if (permissions.isEmpty()) return@collect
                viewModel.setLastPermissionRequest(permissions.firstOrNull() ?: "")
                val allGranted = permissions.all {
                    ContextCompat.checkSelfPermission(this@MainActivity, it) == PackageManager.PERMISSION_GRANTED
                }
                when {
                    allGranted -> {
                        viewModel.onPermissionResult(true)
                    }
                    permissions.any { shouldShowRequestPermissionRationale(it) } -> {
                        val message = when {
                            permissions.contains(Manifest.permission.ACCESS_FINE_LOCATION) -> "Nexus needs location for local weather and nearby device discovery."
                            permissions.contains(Manifest.permission.READ_CALENDAR) -> "Nexus needs calendar access to read your schedule."
                            permissions.any { it.startsWith("android.permission.BLUETOOTH") } -> "Nexus needs Bluetooth permissions to discover nearby mesh devices."
                            permissions.contains(Manifest.permission.RECORD_AUDIO) -> "Nexus needs microphone access for voice commands."
                            else -> "These permissions are needed for the requested feature."
                        }
                        viewModel.showPermissionRationale(permissions, message)
                    }
                    else -> {
                        permissionLauncher.launch(permissions)
                    }
                }
            }
        }

        LaunchedEffect(Unit) {
            viewModel.voicePermissionResult.collect { granted ->
                if (granted) startVoiceInput(viewModel.pendingVoiceTarget)
            }
        }

        // Voice input on wake is now driven by the service launching this
        // activity with EXTRA_WAKE_WORD_VOICE_INPUT (handled in onCreate/
        // onNewIntent/onResume), so the wake word works outside the app too.
        // The event flow is kept for logging only.

        when (val intern = state.internState) {
            is InternProtocolState.Visible -> InternDialog(state = intern)
            else -> Unit
        }

        if (state.showRuleEditor) {
            RuleEditorDialog(
                onDismiss = { viewModel.showRuleEditor(false) },
                onSave = { pattern, actionType, payload ->
                    viewModel.addUserRule(pattern, actionType, payload)
                },
                prefilledPattern = state.ruleEditorPrefill
            )
        }

        state.permissionRationale?.let { rationale ->
            AlertDialog(
                onDismissRequest = { viewModel.dismissPermissionRationale() },
                title = { Text(stringResource(id = R.string.intern_protocol_title)) },
                text = { Text(rationale.message) },
                confirmButton = {
                    TextButton(onClick = { viewModel.onRationaleContinue() }) {
                        Text(stringResource(id = R.string.save))
                    }
                },
                dismissButton = {
                    TextButton(onClick = { viewModel.dismissPermissionRationale() }) {
                        Text(stringResource(id = R.string.cancel))
                    }
                }
            )
        }

        Scaffold(
            containerColor = NexusBackground,
            topBar = {
                NexusTopBar(title = stringResource(id = selectedTab.labelRes))
            },
            bottomBar = {
                NavigationBar(
                    containerColor = NexusNavBar,
                    contentColor = White
                ) {
                    NexusTab.values().forEach { tab ->
                        val isSelected = selectedTab == tab
                        NavigationBarItem(
                            selected = isSelected,
                            onClick = { selectedTab = tab },
                            icon = {
                                Icon(
                                    tab.icon,
                                    contentDescription = stringResource(id = tab.labelRes),
                                    tint = if (isSelected) NexusRed else Color.Gray
                                )
                            },
                            label = {
                                Text(
                                    stringResource(id = tab.labelRes),
                                    color = if (isSelected) White else Color.Gray,
                                    fontSize = 11.sp
                                )
                            },
                            colors = NavigationBarItemDefaults.colors(
                                indicatorColor = NexusSurfaceVariant
                            )
                        )
                    }
                }
            }
        ) { paddingValues ->
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .background(NexusBackground)
                    .padding(paddingValues)
            ) {
                when (selectedTab) {
                    NexusTab.HOME -> HomeTab(
                        viewModel = viewModel,
                        state = state,
                        onCallNexus = {
                            selectedTab = NexusTab.CHAT
                            startVoiceChat()
                        }
                    )
                    NexusTab.CHAT -> ChatTab(viewModel = viewModel, state = state)
                    NexusTab.TALK -> TalkTab(
                        state = state,
                        onTalk = { startVoiceInput() }
                    )
                    NexusTab.LOGS -> LogsTab(state = state)
                    NexusTab.VISION -> VisionTab(
                        state = state,
                        onCameraSelected = { viewModel.selectCamera(it) },
                        onTogglePreview = { viewModel.toggleCameraPreview() },
                        onFpsChanged = { viewModel.setPreviewFps(it) },
                        onSnapshot = { viewModel.takeSnapshot() },
                        onSearch = { viewModel.searchCameras(it) },
                        onLocate = { viewModel.locateItem(it) },
                        onRefreshStatus = { viewModel.refreshServerStatus() }
                    )
                    else -> viewModel.stopCameraPreview()
                    NexusTab.SETTINGS -> SettingsTab(
                        viewModel = viewModel,
                        state = state
                    )
                }
            }
        }

        // Voice enrollment dialog (speaker verification setup)
        if (state.voiceEnrollmentState !is com.nexus.app.ui.viewmodel.VoiceEnrollmentState.Idle) {
            VoiceEnrollmentDialog(
                state = state.voiceEnrollmentState,
                customWakePhrase = state.customWakePhrase,
                onStartRecording = { viewModel.startEnrollmentRecording() },
                onStopRecording = { viewModel.stopEnrollmentRecording() },
                onCancel = { viewModel.cancelVoiceEnrollment() },
                onDismiss = { viewModel.cancelVoiceEnrollment() }
            )
        }

        // In-app voice input (on-device Vosk) — replaces Google's recognizer
        // dialog. Rendered on top of everything, including over the lock screen
        // when the wake word launched us.
        if (state.isListening || state.voicePreparing) {
            VoiceInputOverlay(
                preparing = state.voicePreparing,
                partial = state.voicePartialTranscript,
                onStop = { stopVoiceInput() },
                onCancel = { cancelVoiceInput() }
            )
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // TOP BAR — clean, minimal
    // ═══════════════════════════════════════════════════════════════
    @OptIn(ExperimentalMaterial3Api::class)
    @Composable
    private fun NexusTopBar(title: String) {
        TopAppBar(
            title = {
                Text(
                    text = title,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 18.sp,
                    color = White
                )
            },
            actions = {
                var showHelp by remember { mutableStateOf(false) }
                if (showHelp) {
                    HelpDialog(onDismiss = { showHelp = false })
                }
                IconButton(onClick = { showHelp = true }) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.HelpOutline,
                        contentDescription = "Help",
                        tint = Color.Gray
                    )
                }
            },
            colors = TopAppBarDefaults.topAppBarColors(
                containerColor = NexusBackground
            )
        )
    }

    // ═══════════════════════════════════════════════════════════════
    // SCREEN 1 — HOME (mockup 1.png)
    // ═══════════════════════════════════════════════════════════════
    @Composable
    private fun HomeTab(viewModel: NexusViewModel, state: NexusUiState, onCallNexus: () -> Unit) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Spacer(modifier = Modifier.height(24.dp))

            // — Hero section (y~12% from mockup) —
            Text(
                text = stringResource(id = R.string.home_title),
                fontWeight = FontWeight.Bold,
                fontSize = 42.sp,
                letterSpacing = 8.sp,
                color = White
            )
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = stringResource(id = R.string.home_subtitle),
                fontSize = 14.sp,
                color = Color.Gray,
                letterSpacing = 2.sp
            )

            Spacer(modifier = Modifier.height(36.dp))

            // — DotGrid visualizer —
            Box(
                modifier = Modifier.fillMaxWidth(),
                contentAlignment = Alignment.Center
            ) {
                DotGridVisualizer(
                    active = state.isListening || state.wakeWordEnabled,
                    amplitude = if (state.isListening) 0.9f else 0.35f,
                    modifier = Modifier.size(140.dp)
                )
            }

            Spacer(modifier = Modifier.height(28.dp))

            // — Red call button (y~20%, red accent from mockup) —
            NexusCallButton(
                isListening = state.isListening,
                amplitude = if (state.isListening) 0.6f else 0f,
                onClick = onCallNexus
            )

            Spacer(modifier = Modifier.height(24.dp))

            // — Wake-word toggle (y~27%) —
            WakeWordToggle(
                enabled = state.wakeWordEnabled,
                status = state.wakeWordStatus,
                onToggle = { viewModel.setWakeWordEnabled(it) }
            )

            Spacer(modifier = Modifier.height(20.dp))

            // — Routine suggestion chips (y~37%) —
            RoutineSuggestionChips(
                suggestions = state.routineSuggestions,
                onSuggestion = { suggestion ->
                    viewModel.updateCommandInput(suggestion.input)
                    viewModel.runCommand()
                },
                onDismiss = { suggestion ->
                    viewModel.dismissRoutineSuggestion(suggestion)
                }
            )

            Spacer(modifier = Modifier.height(12.dp))

            // — Quick action row (y~45-57%) —
            QuickActionsRow(onAction = { command ->
                viewModel.updateCommandInput(command)
                viewModel.runCommand()
            })

            Spacer(modifier = Modifier.height(20.dp))

            // — Command input (y~79%) —
            CommandInputField(
                value = state.commandInput,
                isListening = state.isListening,
                onValueChange = viewModel::updateCommandInput,
                onSend = { viewModel.runCommand() },
                onVoiceClick = { startVoiceInput() }
            )

            // — Voice error —
            AnimatedVisibility(
                visible = !state.voiceError.isNullOrBlank(),
                enter = expandVertically() + fadeIn(),
                exit = shrinkVertically() + fadeOut()
            ) {
                Column {
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = state.voiceError ?: "",
                        style = MaterialTheme.typography.bodySmall,
                        color = NexusRed,
                        modifier = Modifier.padding(horizontal = 4.dp)
                    )
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

            // — Last result card —
            LastResultCard(result = state.lastResult)

            Spacer(modifier = Modifier.height(24.dp))
        }
    }

    @Suppress("UNUSED_PARAMETER")
    @Composable
    private fun NexusCallButton(
        isListening: Boolean,
        amplitude: Float,
        onClick: () -> Unit
    ) {
        val pulseScale by animateFloatAsState(
            targetValue = if (isListening) 1.08f else 1f,
            label = "callPulse",
            animationSpec = if (isListening)
                infiniteRepeatable(tween(800), RepeatMode.Reverse) else tween(300)
        )

        val glowAlpha by animateFloatAsState(
            targetValue = if (isListening) 0.3f else 0f,
            label = "callGlow"
        )

        Box(contentAlignment = Alignment.Center) {
            // Glow ring
            if (isListening) {
                Canvas(modifier = Modifier.size(140.dp)) {
                    drawCircle(
                        color = NexusRed.copy(alpha = glowAlpha),
                        radius = size.minDimension / 2,
                        style = Stroke(width = 4.dp.toPx())
                    )
                }
            }

            Button(
                onClick = onClick,
                modifier = Modifier
                    .size(120.dp)
                    .scale(pulseScale),
                shape = CircleShape,
                colors = ButtonDefaults.buttonColors(
                    containerColor = NexusRed,
                    contentColor = White
                ),
                elevation = ButtonDefaults.buttonElevation(
                    defaultElevation = 8.dp,
                    pressedElevation = 2.dp
                )
            ) {
                Icon(
                    imageVector = Icons.Default.Mic,
                    contentDescription = stringResource(id = R.string.talk_to_nexus),
                    modifier = Modifier.size(48.dp),
                    tint = White
                )
            }

            if (isListening) {
                Text(
                    text = "LISTENING",
                    color = NexusRed,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 3.sp,
                    modifier = Modifier
                        .align(Alignment.BottomCenter)
                        .padding(bottom = 12.dp)
                )
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // SCREEN 2 — CHAT (mockup 2.png)
    // ═══════════════════════════════════════════════════════════════
    @Composable
    @Suppress("DEPRECATION")
    private fun ChatTab(viewModel: NexusViewModel, state: NexusUiState) {
        val listState = rememberLazyListState()
        val coroutineScope = rememberCoroutineScope()

        LaunchedEffect(state.chatMessages.size) {
            if (state.chatMessages.isNotEmpty()) {
                coroutineScope.launch {
                    listState.animateScrollToItem(state.chatMessages.size - 1)
                }
            }
        }

        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 16.dp)
        ) {
            // — Purple accent header (from mockup — top area) —
            Card(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 4.dp, bottom = 8.dp),
                shape = RoundedCornerShape(16.dp),
                colors = CardDefaults.cardColors(containerColor = NexusPurple)
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Column {
                        Text(
                            text = "Nexus Chat",
                            fontWeight = FontWeight.SemiBold,
                            fontSize = 16.sp,
                            color = White
                        )
                        Text(
                            text = state.chatBackendStatus,
                            fontSize = 11.sp,
                            color = White.copy(alpha = 0.7f)
                        )
                    }
                    Icon(
                        imageVector = Icons.Default.Message,
                        contentDescription = null,
                        tint = White.copy(alpha = 0.8f),
                        modifier = Modifier.size(28.dp)
                    )
                }
            }

            // LLM offline banner
            if (state.chatBackendStatus.contains("No local LLM")) {
                Card(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(bottom = 8.dp),
                    shape = RoundedCornerShape(12.dp),
                    colors = CardDefaults.cardColors(containerColor = NexusAmber.copy(alpha = 0.15f))
                ) {
                    Row(
                        modifier = Modifier.padding(12.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = "⚠ Local LLM not found",
                            color = NexusAmber,
                            fontSize = 13.sp,
                            modifier = Modifier.weight(1f)
                        )
                        Button(
                            onClick = { viewModel.refreshChatBackend() },
                            colors = ButtonDefaults.buttonColors(containerColor = NexusAmber),
                            shape = RoundedCornerShape(8.dp)
                        ) {
                            Text("Refresh", fontSize = 12.sp)
                        }
                    }
                }
            }

            // Messages list
            if (state.chatMessages.isEmpty()) {
                ChatEmptyState(
                    noLlm = state.chatBackendStatus.contains("No local LLM"),
                    modifier = Modifier.weight(1f)
                )
            } else {
                LazyColumn(
                    state = listState,
                    modifier = Modifier
                        .weight(1f)
                        .fillMaxWidth()
                        .padding(vertical = 4.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp)
                ) {
                    items(state.chatMessages, key = { it.id }) { message ->
                        ChatBubble(message = message)
                    }
                }
            }

            // Confirmation
            if (state.chatPendingConfirmation) {
                ChatConfirmationBar(
                    onApprove = { viewModel.confirmChatCommand() },
                    onCancel = { viewModel.dismissChatConfirmation() }
                )
                Spacer(modifier = Modifier.height(8.dp))
            }

            // — Teal input bar (from mockup ~73-84%) —
            ChatInputBar(
                value = state.chatInput,
                onValueChange = { viewModel.updateChatInput(it) },
                onSend = { viewModel.sendChatMessage() },
                onVoiceClick = { startVoiceChat() }
            )
        }
    }

    @Composable
    private fun ChatBubble(message: ChatMessage) {
        val isUser = message.role == "user"
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start
        ) {
            Surface(
                shape = RoundedCornerShape(
                    topStart = 16.dp,
                    topEnd = 16.dp,
                    bottomStart = if (isUser) 16.dp else 4.dp,
                    bottomEnd = if (isUser) 4.dp else 16.dp
                ),
                color = if (isUser) NexusPurple.copy(alpha = 0.4f) else NexusCardLight,
                shadowElevation = 0.dp,
                modifier = Modifier.widthIn(max = 320.dp)
            ) {
                Column(modifier = Modifier.padding(12.dp)) {
                    Text(
                        text = message.content,
                        color = White,
                        fontSize = 14.sp,
                        lineHeight = 20.sp
                    )
                    if (message.requiresConfirmation) {
                        Text(
                            text = "Awaiting approval",
                            fontSize = 11.sp,
                            color = NexusAmber,
                            modifier = Modifier.padding(top = 4.dp)
                        )
                    }
                }
            }
        }
    }

    @Composable
    private fun ChatConfirmationBar(onApprove: () -> Unit, onCancel: () -> Unit) {
        Card(
            shape = RoundedCornerShape(12.dp),
            colors = CardDefaults.cardColors(containerColor = NexusAmber.copy(alpha = 0.15f))
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    text = "Nexus wants to run a command",
                    color = NexusAmber,
                    fontSize = 13.sp,
                    modifier = Modifier.weight(1f)
                )
                Row {
                    TextButton(onClick = onCancel) {
                        Text("Cancel", color = Color.Gray, fontSize = 12.sp)
                    }
                    Spacer(modifier = Modifier.width(8.dp))
                    Button(
                        onClick = onApprove,
                        colors = ButtonDefaults.buttonColors(containerColor = NexusGreen),
                        shape = RoundedCornerShape(8.dp)
                    ) {
                        Text("Approve", fontSize = 12.sp)
                    }
                }
            }
        }
    }

    @Suppress("DEPRECATION")
    @Composable
    private fun ChatEmptyState(noLlm: Boolean, modifier: Modifier = Modifier) {
        Column(
            modifier = modifier
                .fillMaxWidth()
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Icon(
                imageVector = Icons.Default.Message,
                contentDescription = null,
                modifier = Modifier.size(56.dp),
                tint = Color.Gray.copy(alpha = 0.5f)
            )
            Spacer(modifier = Modifier.height(16.dp))
            Text(
                text = stringResource(id = R.string.chat_empty_title),
                fontWeight = FontWeight.SemiBold,
                fontSize = 18.sp,
                color = White
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = stringResource(id = if (noLlm) R.string.chat_no_llm_body else R.string.chat_empty_body),
                fontSize = 13.sp,
                color = Color.Gray,
                textAlign = TextAlign.Center
            )
            if (noLlm) {
                Spacer(modifier = Modifier.height(16.dp))
                Button(
                    onClick = { viewModel.refreshChatBackend() },
                    colors = ButtonDefaults.buttonColors(containerColor = NexusRed)
                ) {
                    Text("Refresh")
                }
            }
        }
    }

    @Composable
    private fun ChatInputBar(value: String, onValueChange: (String) -> Unit, onSend: () -> Unit, onVoiceClick: () -> Unit) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(NexusTeal, RoundedCornerShape(24.dp))
                .padding(4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            // Voice button
            IconButton(onClick = onVoiceClick) {
                Icon(
                    Icons.Default.Mic,
                    contentDescription = stringResource(id = R.string.voice_input),
                    tint = White.copy(alpha = 0.7f)
                )
            }

            // Text field
            OutlinedTextField(
                value = value,
                onValueChange = onValueChange,
                modifier = Modifier.weight(1f),
                placeholder = {
                    Text(
                        stringResource(id = R.string.chat_input_hint),
                        color = Color.Gray,
                        fontSize = 14.sp
                    )
                },
                textStyle = MaterialTheme.typography.bodyMedium.copy(color = White, fontSize = 14.sp),
                singleLine = true,
                keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
                keyboardActions = KeyboardActions(onSend = { onSend() }),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = Color.Transparent,
                    unfocusedBorderColor = Color.Transparent,
                    cursorColor = NexusRed,
                    focusedContainerColor = Color.Transparent,
                    unfocusedContainerColor = Color.Transparent
                )
            )

            // Send button
            IconButton(
                onClick = onSend,
                colors = IconButtonDefaults.iconButtonColors(
                    containerColor = NexusRed
                )
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.Send,
                    contentDescription = stringResource(id = R.string.send),
                    tint = White,
                    modifier = Modifier.size(20.dp)
                )
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // SCREEN 3 — TALK / DISCUSSION (mockup 3.png)
    // ═══════════════════════════════════════════════════════════════
    @Composable
    private fun TalkTab(
        state: NexusUiState,
        onTalk: () -> Unit
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 20.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Spacer(modifier = Modifier.height(32.dp))

            // — Title (from mockup ~11%) —
            Text(
                text = stringResource(id = R.string.talk_title),
                fontWeight = FontWeight.Bold,
                fontSize = 28.sp,
                letterSpacing = 4.sp,
                color = White
            )

            Spacer(modifier = Modifier.height(8.dp))

            // — Subtitle hint (from mockup ~16%) —
            Text(
                text = stringResource(id = R.string.talk_hint),
                fontSize = 13.sp,
                color = Color.Gray
            )

            Spacer(modifier = Modifier.height(48.dp))

            // — Large animated mic / voice visualizer (from mockup ~69%) —
            Box(
                modifier = Modifier.weight(1f),
                contentAlignment = Alignment.Center
            ) {
                VoiceVisualizer(
                    isActive = state.isListening,
                    modifier = Modifier.size(280.dp)
                )

                // Center mic button
                IconButton(
                    onClick = onTalk,
                    modifier = Modifier
                        .size(100.dp)
                        .clip(CircleShape)
                        .background(
                            if (state.isListening) NexusRed else NexusCardDark
                        )
                ) {
                    Icon(
                        imageVector = Icons.Default.Mic,
                        contentDescription = "Talk",
                        tint = White,
                        modifier = Modifier.size(48.dp)
                    )
                }
            }

            Spacer(modifier = Modifier.height(24.dp))

            // — Status / transcript area (from mockup ~76%) —
            Card(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 16.dp),
                shape = RoundedCornerShape(20.dp),
                colors = CardDefaults.cardColors(containerColor = NexusCardLight)
            ) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    if (state.isListening) {
                        Text(
                            text = "Listening...",
                            color = NexusRed,
                            fontWeight = FontWeight.SemiBold,
                            fontSize = 14.sp,
                            letterSpacing = 2.sp
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        // Animated dots
                        val dotCount by rememberInfiniteTransition().animateFloat(
                            initialValue = 1f,
                            targetValue = 4f,
                            animationSpec = infiniteRepeatable(
                                animation = tween(1000, easing = LinearEasing),
                                repeatMode = RepeatMode.Reverse
                            ),
                            label = "dots"
                        )
                        Text(
                            text = (1..dotCount.toInt()).joinToString("") { "." },
                            color = Color.Gray,
                            fontSize = 24.sp
                        )
                    } else {
                        Text(
                            text = "Tap the mic to start",
                            color = Color.Gray,
                            fontSize = 14.sp
                        )
                    }
                }
            }

            // — Voice error display —
            AnimatedVisibility(
                visible = !state.voiceError.isNullOrBlank(),
                enter = expandVertically() + fadeIn(),
                exit = shrinkVertically() + fadeOut()
            ) {
                Text(
                    text = state.voiceError ?: "",
                    color = NexusRed,
                    fontSize = 12.sp,
                    modifier = Modifier.padding(bottom = 8.dp)
                )
            }
        }
    }

    @Composable
    private fun VoiceVisualizer(isActive: Boolean, modifier: Modifier = Modifier) {
        val transition = rememberInfiniteTransition(label = "voiceViz")
        val phases = remember { List(24) { Random.nextFloat() * PI.toFloat() * 2 } }

        val amplitudes = phases.mapIndexed { i, phase ->
            transition.animateFloat(
                initialValue = 0.3f,
                targetValue = if (isActive) (0.4f + 0.6f * (sin(phase) + 1f) / 2f) else 0.3f,
                animationSpec = infiniteRepeatable(
                    animation = tween(600 + (i * 50) % 400, easing = LinearEasing),
                    repeatMode = RepeatMode.Reverse
                ),
                label = "amp$i"
            )
        }

        Canvas(modifier = modifier) {
            val center = Offset(size.width / 2, size.height / 2)
            val radius = size.minDimension / 2
            val ringRadius = radius * 0.8f
            val pointCount = 24

            // Draw rings
            for (ring in 0..2) {
                val ringAlpha = if (isActive) 0.15f - (ring * 0.04f) else 0.05f
                drawCircle(
                    color = NexusRed.copy(alpha = ringAlpha),
                    radius = radius * (0.6f + ring * 0.2f),
                    style = Stroke(width = 1.dp.toPx())
                )
            }

            // Draw amplitude points
            for (i in 0 until pointCount) {
                val angle = (2.0 * PI * i / pointCount).toFloat()
                val amp = amplitudes[i].value
                val x = center.x + ringRadius * cos(angle) * amp
                val y = center.y + ringRadius * sin(angle) * amp

                val pointRadius = 3.dp.toPx() * (if (isActive) 0.5f + 0.5f * amp else 0.5f)
                drawCircle(
                    color = if (isActive) NexusRed.copy(alpha = 0.6f + 0.4f * amp) else Color.Gray.copy(alpha = 0.3f),
                    radius = pointRadius,
                    center = Offset(x, y)
                )
            }
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // SCREEN 4 — LOGS (mockup 4.png)
    // ═══════════════════════════════════════════════════════════════
    @Suppress("DEPRECATION")
    @Composable
    private fun LogsTab(state: NexusUiState) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(horizontal = 16.dp)
        ) {
            // — Header row —
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "System Activity",
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 14.sp,
                    color = White
                )
                TextButton(onClick = { viewModel.clearLogs() }) {
                    Text(
                        "Clear",
                        color = NexusRed,
                        fontSize = 12.sp
                    )
                }
            }

            // — Log entries —
            if (state.logs.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(32.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Icon(
                        imageVector = Icons.Default.List,
                        contentDescription = null,
                        modifier = Modifier.size(48.dp),
                            tint = Color.Gray.copy(alpha = 0.4f)
                        )
                        Spacer(modifier = Modifier.height(12.dp))
                        Text(
                            text = "No activity yet",
                            color = Color.Gray,
                            fontSize = 14.sp
                        )
                    }
                }
            } else {
                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                    modifier = Modifier.fillMaxSize()
                ) {
                    items(state.logs.size) { index ->
                        val log = state.logs.reversed()[index]
                        LogEntryRow(log = log)
                    }
                }
            }
        }
    }

    @Composable
    private fun LogEntryRow(log: String) {
        // Parse log format: "[LEVEL] message" or "LEVEL: message"
        val level = when {
            log.contains("ERROR", ignoreCase = true) || log.contains("FAIL", ignoreCase = true) -> "ERROR"
            log.contains("WARN", ignoreCase = true) -> "WARN"
            log.contains("SUCCESS", ignoreCase = true) || log.contains("OK", ignoreCase = true) -> "OK"
            else -> "INFO"
        }

        val badgeColor = when (level) {
            "ERROR" -> NexusRed
            "WARN" -> NexusAmber
            "OK" -> NexusGreen
            else -> Color.Gray
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 2.dp),
            verticalAlignment = Alignment.Top
        ) {
            // Level badge
            Surface(
                shape = RoundedCornerShape(4.dp),
                color = badgeColor.copy(alpha = 0.15f),
                modifier = Modifier.padding(end = 8.dp, top = 2.dp)
            ) {
                Text(
                    text = level,
                    color = badgeColor,
                    fontSize = 9.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                )
            }

            // Log message
            Text(
                text = log,
                color = Color.Gray,
                fontSize = 11.sp,
                lineHeight = 15.sp,
                fontFamily = FontFamily.Monospace,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis
            )
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // SCREEN 5 — SETTINGS (mockup 5.png)
    // ═══════════════════════════════════════════════════════════════
    @Composable
    private fun SettingsTab(viewModel: NexusViewModel, state: NexusUiState) {
        val readyLanguages by viewModel.readyLanguages.collectAsState()
        val nodes by viewModel.meshNodes.collectAsState()

        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp)
        ) {
            Spacer(modifier = Modifier.height(8.dp))

            // — Dashboard card (from mockup ~7-26%) —
            DashboardHeader(
                mode = state.executionMode,
                ramMb = state.availableRamMb,
                totalMb = state.totalRamMb
            )

            Spacer(modifier = Modifier.height(16.dp))

            // — Connectivity / Devices card (from mockup ~31-47%) —
            ConnectivityCard(
                nodes = nodes,
                onPairDevice = { viewModel.startMeshService() }
            )

            Spacer(modifier = Modifier.height(16.dp))

            // — Privacy transparency (what Nexus talks to — and to whom) —
            PrivacyCard()

            Spacer(modifier = Modifier.height(16.dp))

            // — Wake word & Language card —
            LanguageSelector(
                currentLanguage = state.wakeWordLanguage,
                downloadLanguage = state.modelDownloadLanguage,
                downloadProgress = state.modelDownloadProgress,
                languages = viewModel.getAvailableLanguages(),
                readyLanguages = readyLanguages,
                onLanguageSelected = { viewModel.changeWakeWordLanguage(it) },
                onDownloadClicked = { viewModel.downloadLanguage(it) },
                onPruneClicked = { keepEnglish -> viewModel.pruneInactiveModels(keepEnglish) }
            )

            Spacer(modifier = Modifier.height(16.dp))

            // — Wake word toggle —
            WakeWordToggle(
                enabled = state.wakeWordEnabled,
                status = state.wakeWordStatus,
                onToggle = { viewModel.setWakeWordEnabled(it) }
            )

            Spacer(modifier = Modifier.height(16.dp))

            // — One-shot wake (command follows the wake word in one utterance) —
            OneShotWakeCard(
                enabled = state.oneShotWake,
                wakeWordEnabled = state.wakeWordEnabled,
                onToggle = { viewModel.setOneShotWake(it) }
            )

            Spacer(modifier = Modifier.height(16.dp))

            // — Voice accuracy (larger on-device English model for fewer mishearings) —
            VoiceAccuracyCard(
                enabled = state.highAccuracyVoice,
                ready = state.highAccuracyVoiceReady,
                downloading = state.highAccuracyVoiceDownloading,
                progress = state.highAccuracyVoiceProgress,
                language = state.wakeWordLanguage,
                onToggle = { viewModel.setHighAccuracyVoice(it) }
            )

            Spacer(modifier = Modifier.height(16.dp))

            // — Battery optimization (keep the wake word alive overnight) —
            BatteryOptimizationCard(
                exempt = state.batteryOptimizationExempt,
                onRequestExemption = { viewModel.requestBatteryOptimizationExemption() }
            )

            Spacer(modifier = Modifier.height(16.dp))

            // — Speaker verification (voice enrollment) —
            VoiceEnrollmentCard(
                enrolled = state.voiceprintEnrolled,
                verificationEnabled = state.voiceprintVerificationEnabled,
                onStartEnrollment = { viewModel.startVoiceEnrollment() },
                onToggleVerification = { viewModel.setSpeakerVerificationEnabled(it) },
                onClearEnrollment = { viewModel.clearVoiceEnrollment() }
            )

            Spacer(modifier = Modifier.height(16.dp))

            // — Skills card —
            SkillsCard(
                installedSkills = state.installedSkills,
                availableSkills = state.availableSkills,
                loading = state.skillsLoading,
                statusMessage = state.skillStatusMessage,
                onBrowse = { viewModel.browseAvailableSkills() },
                onInstall = { viewModel.installSkill(it) },
                onToggle = { id, enabled -> viewModel.toggleSkill(id, enabled) },
                onRemove = { viewModel.removeSkill(it) },
                onUpdate = { viewModel.updateSkill(it) },
                onDismissStatus = { viewModel.dismissSkillStatus() }
            )

            Spacer(modifier = Modifier.height(16.dp))

            // — Rule editor card —
            Card(
                modifier = Modifier.fillMaxWidth(),
                shape = RoundedCornerShape(16.dp),
                colors = CardDefaults.cardColors(containerColor = NexusCardDark)
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { viewModel.showRuleEditor(true) }
                        .padding(16.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        imageVector = Icons.Default.Bolt,
                        contentDescription = null,
                        tint = NexusRed,
                        modifier = Modifier.size(24.dp)
                    )
                    Spacer(modifier = Modifier.width(12.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "Teach Nexus",
                            fontWeight = FontWeight.Medium,
                            fontSize = 15.sp,
                            color = White
                        )
                        Text(
                            text = "Add custom rules for unknown commands",
                            fontSize = 12.sp,
                            color = Color.Gray
                        )
                    }
                    Icon(
                        imageVector = Icons.Default.Settings,
                        contentDescription = null,
                        tint = Color.Gray,
                        modifier = Modifier.size(20.dp)
                    )
                }
            }

            Spacer(modifier = Modifier.height(24.dp))
        }
    }

    // ═══════════════════════════════════════════════════════════════
    // SHARED COMPONENTS
    // ═══════════════════════════════════════════════════════════════

    @Composable
    private fun WakeWordToggle(enabled: Boolean, onToggle: (Boolean) -> Unit, status: String? = null) {
        val context = LocalContext.current
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = NexusCardDark)
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Hands-free wake",
                        fontWeight = FontWeight.Medium,
                        fontSize = 15.sp,
                        color = White
                    )
                    val statusText = when {
                        !status.isNullOrBlank() -> status
                        enabled -> "Wake word active"
                        else -> "Say the wake word to start voice input"
                    }
                    Text(
                        text = statusText,
                        fontSize = 12.sp,
                        color = if (status?.contains("failed") == true) NexusRed else Color.Gray,
                        modifier = Modifier.padding(top = 2.dp)
                    )
                }
                Switch(
                    checked = enabled,
                    onCheckedChange = { enable ->
                        if (enable && ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                            viewModel.requestWakeWordPermission()
                        } else {
                            onToggle(enable)
                        }
                    },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = White,
                        checkedTrackColor = NexusRed,
                        uncheckedThumbColor = Color.Gray,
                        uncheckedTrackColor = NexusCardLight
                    )
                )
            }
        }
    }

    @Composable
    private fun BatteryOptimizationCard(
        exempt: Boolean,
        onRequestExemption: () -> Unit
    ) {
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = NexusCardDark)
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Default.Bolt,
                        contentDescription = null,
                        tint = if (exempt) NexusGreen else NexusAmber,
                        modifier = Modifier.size(22.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "Stay awake overnight",
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 15.sp,
                        color = White
                    )
                }
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    text = if (exempt) {
                        "Battery optimization off — the wake word stays alive in the background."
                    } else {
                        "Battery optimization is on. The OS may stop the wake-word listener after hours of inactivity."
                    },
                    fontSize = 12.sp,
                    color = Color.Gray
                )
                Spacer(modifier = Modifier.height(12.dp))
                Button(
                    onClick = onRequestExemption,
                    enabled = !exempt,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = if (exempt) NexusGreen else NexusRed,
                        contentColor = White
                    )
                ) {
                    Icon(
                        imageVector = Icons.Default.Bolt,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = if (exempt) "Optimization disabled ✓" else "Exempt from battery optimization",
                        fontWeight = FontWeight.Medium,
                        fontSize = 13.sp
                    )
                }
            }
        }
    }

    /**
     * Speaker verification (voice enrollment) card: guides the user through
     * recording their voice to create a voiceprint, so only their voice
     * triggers Nexus — like Siri's "Hey Siri" setup.
     */
    @Composable
    private fun SkillsCard(
        installedSkills: List<com.nexus.app.skill.InstalledSkill>,
        availableSkills: List<com.nexus.app.skill.SkillManifest>,
        loading: Boolean,
        statusMessage: String?,
        onBrowse: () -> Unit,
        onInstall: (com.nexus.app.skill.SkillManifest) -> Unit,
        onToggle: (String, Boolean) -> Unit,
        onRemove: (String) -> Unit,
        onUpdate: (String) -> Unit,
        onDismissStatus: () -> Unit
    ) {
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = NexusCardDark)
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Default.Bolt,
                        contentDescription = null,
                        tint = NexusPurple,
                        modifier = Modifier.size(22.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "Skills",
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 15.sp,
                        color = White
                    )
                }
                Spacer(modifier = Modifier.height(6.dp))
                Text(
                    text = "Download command packs from the community. Nexus starts empty — skills teach it new abilities.",
                    fontSize = 12.sp,
                    color = Color.Gray
                )

                // Status message
                if (!statusMessage.isNullOrBlank()) {
                    Spacer(modifier = Modifier.height(8.dp))
                    Card(
                        shape = RoundedCornerShape(8.dp),
                        colors = CardDefaults.cardColors(containerColor = NexusGreen.copy(alpha = 0.15f))
                    ) {
                        Row(
                            modifier = Modifier.padding(8.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text(
                                text = statusMessage,
                                fontSize = 11.sp,
                                color = NexusGreen,
                                modifier = Modifier.weight(1f)
                            )
                            TextButton(onClick = onDismissStatus) {
                                Text("OK", fontSize = 11.sp)
                            }
                        }
                    }
                }

                // Installed skills
                if (installedSkills.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(12.dp))
                    Text(
                        text = "Installed (${installedSkills.size})",
                        fontWeight = FontWeight.Medium,
                        fontSize = 13.sp,
                        color = White
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    installedSkills.forEach { skill ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = skill.manifest.name,
                                    fontSize = 13.sp,
                                    color = White
                                )
                                Text(
                                    text = "v${skill.manifest.version} by ${skill.manifest.author}",
                                    fontSize = 10.sp,
                                    color = Color.Gray
                                )
                            }
                            Switch(
                                checked = skill.enabled,
                                onCheckedChange = { enabled -> onToggle(skill.manifest.id, enabled) },
                                colors = SwitchDefaults.colors(
                                    checkedThumbColor = White,
                                    checkedTrackColor = NexusRed,
                                    uncheckedThumbColor = Color.Gray,
                                    uncheckedTrackColor = NexusCardLight
                                )
                            )
                        }
                    }
                }

                // Browse button
                Spacer(modifier = Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(
                        onClick = onBrowse,
                        enabled = !loading,
                        modifier = Modifier.weight(1f),
                        shape = RoundedCornerShape(12.dp),
                        colors = ButtonDefaults.buttonColors(containerColor = NexusRed)
                    ) {
                        if (loading) {
                            Text("Loading...", fontSize = 12.sp)
                        } else {
                            Text("Browse Skills", fontSize = 12.sp)
                        }
                    }
                }

                // Available skills
                if (availableSkills.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(12.dp))
                    Text(
                        text = "Available (${availableSkills.size})",
                        fontWeight = FontWeight.Medium,
                        fontSize = 13.sp,
                        color = White
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    availableSkills.forEach { skill ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    text = skill.name,
                                    fontSize = 13.sp,
                                    color = White
                                )
                                Text(
                                    text = "v${skill.version} — ${skill.description.take(60)}",
                                    fontSize = 10.sp,
                                    color = Color.Gray
                                )
                            }
                            Button(
                                onClick = { onInstall(skill) },
                                enabled = !loading,
                                shape = RoundedCornerShape(8.dp),
                                colors = ButtonDefaults.buttonColors(containerColor = NexusGreen),
                                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 4.dp)
                            ) {
                                Text("Install", fontSize = 11.sp)
                            }
                        }
                    }
                }

                if (installedSkills.isEmpty() && availableSkills.isEmpty() && !loading) {
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = "No skills installed. Tap Browse to discover community skills.",
                        fontSize = 11.sp,
                        color = Color.Gray
                    )
                }
            }
        }
    }

    @Composable
    private fun VoiceEnrollmentCard(
        enrolled: Boolean,
        verificationEnabled: Boolean,
        onStartEnrollment: () -> Unit,
        onToggleVerification: (Boolean) -> Unit,
        onClearEnrollment: () -> Unit
    ) {
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = NexusCardDark)
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Default.RecordVoiceOver,
                        contentDescription = null,
                        tint = if (enrolled) NexusGreen else NexusRed,
                        modifier = Modifier.size(22.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "Speaker verification",
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 15.sp,
                        color = White
                    )
                }
                Spacer(modifier = Modifier.height(6.dp))
                Text(
                    text = if (enrolled)
                        "Nexus only responds to your voice — even in crowded places."
                    else
                        "Teach Nexus your voice so it ignores other people and background noise.",
                    fontSize = 12.sp,
                    color = Color.Gray
                )
                Spacer(modifier = Modifier.height(12.dp))
                if (enrolled) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            text = if (verificationEnabled) "Verification active ✓" else "Verification paused",
                            fontSize = 11.sp,
                            color = if (verificationEnabled) NexusGreen else Color.Gray,
                            modifier = Modifier.weight(1f)
                        )
                        Switch(
                            checked = verificationEnabled,
                            onCheckedChange = onToggleVerification,
                            colors = SwitchDefaults.colors(
                                checkedThumbColor = White,
                                checkedTrackColor = NexusRed,
                                uncheckedThumbColor = Color.Gray,
                                uncheckedTrackColor = NexusCardLight
                            )
                        )
                    }
                    Spacer(modifier = Modifier.height(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(
                            onClick = onStartEnrollment,
                            modifier = Modifier.weight(1f),
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = NexusRed)
                        ) {
                            Text("Re-enroll", fontSize = 12.sp)
                        }
                        OutlinedButton(
                            onClick = onClearEnrollment,
                            modifier = Modifier.weight(1f),
                            colors = ButtonDefaults.outlinedButtonColors(contentColor = Color.Gray)
                        ) {
                            Text("Clear", fontSize = 12.sp)
                        }
                    }
                } else {
                    Button(
                        onClick = onStartEnrollment,
                        modifier = Modifier.fillMaxWidth(),
                        shape = RoundedCornerShape(12.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = NexusRed,
                            contentColor = White
                        )
                    ) {
                        Icon(
                            imageVector = Icons.Default.Mic,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp)
                        )
                        Spacer(modifier = Modifier.width(8.dp))
                        Text(
                            text = "Enroll my voice",
                            fontWeight = FontWeight.Medium,
                            fontSize = 13.sp
                        )
                    }
                }
            }
        }
    }

    /**
     * One-shot wake: after "hey nexus", keep listening and run whatever command
     * follows in the same utterance — no overlay, no second utterance. When
     * Hands-free wake is off, the toggle is disabled since there is no listener
     * to capture the command.
     */
    @Composable
    private fun OneShotWakeCard(
        enabled: Boolean,
        wakeWordEnabled: Boolean,
        onToggle: (Boolean) -> Unit
    ) {
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = NexusCardDark)
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Default.RecordVoiceOver,
                        contentDescription = null,
                        tint = if (enabled) NexusGreen else NexusRed,
                        modifier = Modifier.size(22.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "One-shot wake",
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 15.sp,
                        color = White
                    )
                }
                Spacer(modifier = Modifier.height(6.dp))
                Text(
                    text = "Say the wake word and your command in one breath — \"hey nexus, play my flow\" — and Nexus runs it immediately, no overlay.",
                    fontSize = 12.sp,
                    color = Color.Gray
                )
                Spacer(modifier = Modifier.height(8.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text(
                        text = when {
                            !wakeWordEnabled -> "Turn on Hands-free wake first"
                            enabled -> "Command runs right after the wake word ✓"
                            else -> "Wake word opens voice input as usual"
                        },
                        fontSize = 11.sp,
                        color = if (enabled && wakeWordEnabled) NexusGreen else Color.Gray,
                        modifier = Modifier.weight(1f)
                    )
                    Switch(
                        checked = enabled,
                        onCheckedChange = onToggle,
                        enabled = wakeWordEnabled,
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = White,
                            checkedTrackColor = NexusRed,
                            uncheckedThumbColor = Color.Gray,
                            uncheckedTrackColor = NexusCardLight
                        )
                    )
                }
            }
        }
    }

    /**
     * Opt-in higher-accuracy English voice model. The bundled small Vosk model
     * is fast and free but mishears in noise; the -lgraph model (≈130 MB, one
     * download) is dramatically better at transcribing commands. English only.
     */
    @Composable
    private fun VoiceAccuracyCard(
        enabled: Boolean,
        ready: Boolean,
        downloading: Boolean,
        progress: Float?,
        language: String,
        onToggle: (Boolean) -> Unit
    ) {
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = NexusCardDark)
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Default.RecordVoiceOver,
                        contentDescription = null,
                        tint = if (enabled) NexusGreen else NexusRed,
                        modifier = Modifier.size(22.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "Voice accuracy",
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 15.sp,
                        color = White
                    )
                }
                Spacer(modifier = Modifier.height(6.dp))
                Text(
                    text = "Use the larger on-device English model (≈130 MB) so Nexus mishears you less. English only.",
                    fontSize = 12.sp,
                    color = Color.Gray
                )
                if (downloading) {
                    Spacer(modifier = Modifier.height(10.dp))
                    Text(
                        text = "Downloading high-accuracy model… ${((progress ?: 0f) * 100).toInt()}%",
                        fontSize = 11.sp,
                        color = Color.Gray
                    )
                    Spacer(modifier = Modifier.height(6.dp))
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(4.dp)
                            .clip(RoundedCornerShape(2.dp))
                            .background(NexusCardLight)
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth(progress ?: 0f)
                                .height(4.dp)
                                .clip(RoundedCornerShape(2.dp))
                                .background(NexusRed)
                        )
                    }
                }
                Spacer(modifier = Modifier.height(6.dp))
                val status = when {
                    downloading -> "Downloading high-accuracy model…"
                    enabled && ready -> "High-accuracy English model active ✓"
                    enabled && language != "en" -> "Active language isn't English — using the small model"
                    enabled -> "High-accuracy model not downloaded yet"
                    else -> "Using the small on-device model"
                }
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Text(
                        text = status,
                        fontSize = 11.sp,
                        color = if (enabled && ready) NexusGreen else Color.Gray,
                        modifier = Modifier.weight(1f)
                    )
                    Switch(
                        checked = enabled,
                        onCheckedChange = onToggle,
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = White,
                            checkedTrackColor = NexusRed,
                            uncheckedThumbColor = Color.Gray,
                            uncheckedTrackColor = NexusCardLight
                        )
                    )
                }
            }
        }
    }

    /**
     * Privacy transparency card: shows exactly what Nexus talks to (and to
     * whom) so the user can see that voice + chat never leave their devices.
     *
     * KEEP IN SYNC WITH THE PRIVACY AUDIT: these rows must stay accurate if a
     * network endpoint is ever added/removed (chat LLM = 127.0.0.1 only, voice
     * = on-device Vosk, speech models = alphacephei.com, weather = open-meteo.com,
     * jokes = jokeapi.dev; no analytics or crash reporting).
     */
    @Composable
    private fun PrivacyCard() {
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = NexusCardDark)
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Default.Lock,
                        contentDescription = null,
                        tint = NexusGreen,
                        modifier = Modifier.size(22.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = "Privacy",
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 15.sp,
                        color = White
                    )
                }
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = "Nothing you say or type is sent to Google.",
                    fontSize = 12.sp,
                    color = Color.Gray
                )
                Spacer(modifier = Modifier.height(12.dp))

                PrivacyRow(
                    staysLocal = true,
                    title = "Voice input",
                    detail = "On-device Vosk — nothing leaves your phone"
                )
                PrivacyRow(
                    staysLocal = true,
                    title = "Chat brain",
                    detail = "Local LLM only (Ollama / LM Studio / llama.cpp on 127.0.0.1)"
                )
                PrivacyRow(
                    staysLocal = true,
                    title = "Device mesh",
                    detail = "Encrypted, local network only"
                )
                PrivacyRow(
                    staysLocal = false,
                    title = "Speech models",
                    detail = "Downloaded from alphacephei.com — not Google"
                )
                PrivacyRow(
                    staysLocal = false,
                    title = "Weather & jokes",
                    detail = "open-meteo.com / jokeapi.dev — only when you ask"
                )
                PrivacyRow(
                    staysLocal = true,
                    title = "Trackers & ads",
                    detail = "None — no analytics, no crash reporting"
                )
            }
        }
    }

    @Composable
    private fun PrivacyRow(staysLocal: Boolean, title: String, detail: String) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = if (staysLocal) Icons.Default.Lock else Icons.Default.LockOpen,
                contentDescription = null,
                tint = if (staysLocal) NexusGreen else NexusAmber,
                modifier = Modifier.size(14.dp)
            )
            Spacer(modifier = Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = title,
                    fontSize = 13.sp,
                    color = White,
                    fontWeight = FontWeight.Medium
                )
                Text(
                    text = detail,
                    fontSize = 11.sp,
                    color = Color.Gray
                )
            }
        }
    }

    @Composable
    fun DashboardHeader(mode: ExecutionMode, ramMb: Long, totalMb: Long) {
        val (modeLabel, modeColor) = when (mode) {
            ExecutionMode.THIN_NODE -> stringResource(id = R.string.mode_thin_node) to NexusAmber
            ExecutionMode.STANDARD_EDGE -> stringResource(id = R.string.mode_standard_edge) to NexusGreen
        }

        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(20.dp),
            colors = CardDefaults.cardColors(containerColor = NexusCardDark)
        ) {
            Column(modifier = Modifier.padding(20.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = "NEXUS",
                            fontWeight = FontWeight.Bold,
                            fontSize = 11.sp,
                            letterSpacing = 3.sp,
                            color = Color.Gray
                        )
                        Spacer(modifier = Modifier.height(4.dp))
                        Text(
                            text = modeLabel,
                            fontWeight = FontWeight.SemiBold,
                            fontSize = 22.sp,
                            color = modeColor,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis
                        )
                    }
                    ModeDot(mode = mode)
                }
                Spacer(modifier = Modifier.height(16.dp))
                // RAM bar
                val ramRatio = if (totalMb > 0) ramMb.toFloat() / totalMb.toFloat() else 0f
                Column {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Text(
                            text = "RAM",
                            fontSize = 12.sp,
                            color = Color.Gray
                        )
                        Text(
                            text = "$ramMb / $totalMb MB",
                            fontSize = 12.sp,
                            color = Color.Gray
                        )
                    }
                    Spacer(modifier = Modifier.height(6.dp))
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(4.dp)
                            .clip(RoundedCornerShape(2.dp))
                            .background(NexusCardLight)
                    ) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth(ramRatio)
                                .height(4.dp)
                                .clip(RoundedCornerShape(2.dp))
                                .background(
                                    when {
                                        ramRatio > 0.8f -> NexusRed
                                        ramRatio > 0.6f -> NexusAmber
                                        else -> NexusGreen
                                    }
                                )
                        )
                    }
                }
            }
        }
    }

    @Composable
    private fun ModeDot(mode: ExecutionMode) {
        val color = when (mode) {
            ExecutionMode.THIN_NODE -> NexusAmber
            ExecutionMode.STANDARD_EDGE -> NexusGreen
        }
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(12.dp))
                .background(color.copy(alpha = 0.15f)),
            contentAlignment = Alignment.Center
        ) {
            Box(
                modifier = Modifier
                    .size(12.dp)
                    .clip(CircleShape)
                    .background(color)
            )
        }
    }

    @Composable
    private fun ConnectivityCard(nodes: List<MeshNode>, onPairDevice: () -> Unit) {
        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = NexusCardDark)
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Icon(
                        imageVector = Icons.Default.Hub,
                        contentDescription = null,
                        tint = NexusRed,
                        modifier = Modifier.size(22.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = stringResource(id = R.string.settings_connectivity),
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 15.sp,
                        color = White
                    )
                }
                Spacer(modifier = Modifier.height(8.dp))
                Text(
                    text = "${nodes.size} device${if (nodes.size != 1) "s" else ""} on mesh",
                    fontSize = 12.sp,
                    color = Color.Gray
                )
                Spacer(modifier = Modifier.height(12.dp))
                Button(
                    onClick = onPairDevice,
                    modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(12.dp),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = NexusRed,
                        contentColor = White
                    )
                ) {
                    Icon(
                        imageVector = Icons.Default.Hub,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text(
                        text = stringResource(id = R.string.settings_pair_device),
                        fontWeight = FontWeight.Medium
                    )
                }

                if (nodes.isNotEmpty()) {
                    Spacer(modifier = Modifier.height(12.dp))
                    nodes.take(3).forEach { node ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(
                                    imageVector = if (viewModel.isPaired(node)) Icons.Default.Lock else Icons.Default.LockOpen,
                                    contentDescription = null,
                                    tint = if (viewModel.isPaired(node)) NexusGreen else Color.Gray,
                                    modifier = Modifier.size(14.dp)
                                )
                                Spacer(modifier = Modifier.width(8.dp))
                                Text(
                                    text = node.name,
                                    fontSize = 13.sp,
                                    color = White
                                )
                            }
                            Icon(
                                imageVector = Icons.Default.Hub,
                                contentDescription = null,
                                tint = if (node.isReachable) NexusGreen else Color.Gray.copy(alpha = 0.4f),
                                modifier = Modifier.size(16.dp)
                            )
                        }
                    }
                    if (nodes.size > 3) {
                        Text(
                            text = "+${nodes.size - 3} more",
                            fontSize = 12.sp,
                            color = Color.Gray,
                            modifier = Modifier.padding(top = 4.dp)
                        )
                    }
                }
            }
        }
    }

    @Composable
    fun LanguageSelector(
        currentLanguage: String,
        downloadLanguage: String?,
        downloadProgress: Float?,
        languages: List<VoskModelManager.Language>,
        readyLanguages: Set<String>,
        onLanguageSelected: (String) -> Unit,
        onDownloadClicked: (String) -> Unit,
        onPruneClicked: (Boolean) -> Unit
    ) {
        var expanded by remember { mutableStateOf(false) }
        val current = languages.find { it.code == currentLanguage }

        Card(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = NexusCardDark)
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text(
                    text = "Wake-word language",
                    fontWeight = FontWeight.Medium,
                    fontSize = 15.sp,
                    color = White
                )
                Spacer(modifier = Modifier.height(8.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = current?.displayName ?: currentLanguage,
                        fontSize = 14.sp,
                        color = Color.Gray
                    )
                    TextButton(onClick = { expanded = true }) {
                        Text("Change", color = NexusRed, fontSize = 12.sp)
                    }
                }
                downloadLanguage?.let { lang ->
                    downloadProgress?.let { progress ->
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = "Downloading $lang… ${(progress * 100).toInt()}%",
                            fontSize = 11.sp,
                            color = Color.Gray
                        )
                        Spacer(modifier = Modifier.height(4.dp))
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(4.dp)
                                .clip(RoundedCornerShape(2.dp))
                                .background(NexusCardLight)
                        ) {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth(progress)
                                    .height(4.dp)
                                    .clip(RoundedCornerShape(2.dp))
                                    .background(NexusRed)
                            )
                        }
                    }
                }
            }
        }

        if (expanded) {
            AlertDialog(
                onDismissRequest = { expanded = false },
                title = {
                    Text(
                        "Select wake-word language",
                        color = White
                    )
                },
                containerColor = NexusCardDark,
                text = {
                    Column {
                        languages.forEach { lang ->
                            val isReady = lang.bundled || readyLanguages.contains(lang.code)
                            val isActive = lang.code == currentLanguage
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(vertical = 4.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(
                                    text = "${lang.displayName} (${lang.code})",
                                    color = White,
                                    fontSize = 14.sp,
                                    modifier = Modifier.weight(1f)
                                )
                                when {
                                    isActive -> Text(
                                        text = "Active",
                                        color = NexusGreen,
                                        fontSize = 12.sp
                                    )
                                    isReady -> TextButton(onClick = { onLanguageSelected(lang.code); expanded = false }) {
                                        Text("Use", color = NexusRed, fontSize = 12.sp)
                                    }
                                    else -> TextButton(onClick = { onDownloadClicked(lang.code); expanded = false }) {
                                        Text("Download", color = NexusRed, fontSize = 12.sp)
                                    }
                                }
                            }
                        }
                        Spacer(modifier = Modifier.height(12.dp))
                        TextButton(
                            onClick = { onPruneClicked(true); expanded = false },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text("Delete inactive (keep English)", color = Color.Gray, fontSize = 12.sp)
                        }
                        TextButton(
                            onClick = { onPruneClicked(false); expanded = false },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text("Delete inactive (all)", color = Color.Gray, fontSize = 12.sp)
                        }
                    }
                },
                confirmButton = {
                    TextButton(onClick = { expanded = false }) {
                        Text("Close", color = Color.Gray)
                    }
                }
            )
        }
    }

    @Composable
    fun RoutineSuggestionChips(
        suggestions: List<RoutineSuggestion>,
        onSuggestion: (RoutineSuggestion) -> Unit,
        onDismiss: (RoutineSuggestion) -> Unit
    ) {
        AnimatedVisibility(
            visible = suggestions.isNotEmpty(),
            enter = expandVertically() + fadeIn(),
            exit = shrinkVertically() + fadeOut()
        ) {
            Column {
                Text(
                    text = stringResource(id = R.string.suggestions_label),
                    fontSize = 11.sp,
                    color = Color.Gray,
                    modifier = Modifier.padding(start = 4.dp, bottom = 6.dp)
                )
                LazyRow(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    contentPadding = PaddingValues(vertical = 4.dp)
                ) {
                    items(suggestions) { suggestion ->
                        SuggestionChip(
                            label = suggestion.displayText,
                            onClick = { onSuggestion(suggestion) },
                            onDismiss = { onDismiss(suggestion) }
                        )
                    }
                }
            }
        }
    }

    @Composable
    private fun SuggestionChip(
        label: String,
        onClick: () -> Unit,
        onDismiss: () -> Unit
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .background(NexusCardDark, RoundedCornerShape(10.dp))
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .clickable(onClick = onClick)
                    .padding(start = 12.dp, top = 6.dp, bottom = 6.dp)
            ) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.HelpOutline,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp),
                    tint = NexusRed
                )
                Spacer(modifier = Modifier.width(6.dp))
                Text(
                    text = label,
                    fontWeight = FontWeight.Medium,
                    fontSize = 13.sp,
                    color = White
                )
            }
            IconButton(
                onClick = onDismiss,
                modifier = Modifier.size(40.dp)
            ) {
                Icon(
                    imageVector = Icons.Default.Close,
                    contentDescription = "Dismiss",
                    modifier = Modifier.size(16.dp),
                    tint = Color.Gray
                )
            }
        }
    }

    @Composable
    fun QuickActionsRow(onAction: (String) -> Unit) {
        val actions = listOf(
            "Flashlight" to "Turn on flashlight",
            "Timer" to "Set a timer for 5 minutes",
            "Weather" to "What's the weather",
            "Schedule" to "My schedule today",
            "Navigate" to "Navigate to home",
            "Music" to "Play chill tunes",
            "Roll dice" to "Roll a dice",
            "Joke" to "Tell me a joke",
            "Info" to "What time is it"
        )

        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            contentPadding = PaddingValues(vertical = 4.dp)
        ) {
            items(actions) { (label, command) ->
                FilterChip(
                    selected = false,
                    onClick = { onAction(command) },
                    label = {
                        Text(
                            label,
                            fontSize = 12.sp,
                            color = White
                        )
                    },                        colors = FilterChipDefaults.filterChipColors(
                        containerColor = NexusCardDark,
                        labelColor = White
                    ),
                    shape = RoundedCornerShape(10.dp)
                )
            }
        }
    }

    @Composable
    fun LastResultCard(result: CommandResult?) {
        val containerColor = when (result?.status) {
            CommandStatus.VERIFIED_SUCCESS -> NexusCardDark
            CommandStatus.PENDING_HANDOFF -> NexusCardDark
            CommandStatus.FAILED -> NexusRed.copy(alpha = 0.1f)
            null -> NexusCardDark
        }
        val borderColor = when (result?.status) {
            CommandStatus.VERIFIED_SUCCESS -> NexusGreen.copy(alpha = 0.3f)
            CommandStatus.FAILED -> NexusRed.copy(alpha = 0.3f)
            else -> Color.Transparent
        }

        Card(
            modifier = Modifier
                .fillMaxWidth().animateContentSize(animationSpec = spring()),
            shape = RoundedCornerShape(16.dp),
            colors = CardDefaults.cardColors(containerColor = containerColor),
            border = if (borderColor != Color.Transparent) BorderStroke(
                1.dp, borderColor
            ) else null
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Text(
                    text = result?.action?.name ?: stringResource(id = R.string.result_label),
                    fontWeight = FontWeight.Medium,
                    fontSize = 11.sp,
                    color = NexusRed,
                    letterSpacing = 1.sp
                )
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = result?.message ?: stringResource(id = R.string.result_placeholder),
                    fontSize = 14.sp,
                    color = if (result == null) Color.Gray else White
                )
            }
        }
    }

    @Composable
    fun CommandInputField(
        value: String,
        isListening: Boolean,
        onValueChange: (String) -> Unit,
        onSend: () -> Unit,
        onVoiceClick: () -> Unit
    ) {
        val pulseScale by animateFloatAsState(
            targetValue = if (isListening) 1.15f else 1f,
            label = "MicPulse"
        )

        val borderColor by animateColorAsState(
            targetValue = if (isListening) NexusRed.copy(alpha = 0.7f) else NexusCardLight,
            label = "borderColor"
        )

        OutlinedTextField(
            value = value,
            onValueChange = onValueChange,
            placeholder = {
                Text(
                    stringResource(id = R.string.hint_command),
                    color = Color.Gray,
                    fontSize = 14.sp
                )
            },
            textStyle = MaterialTheme.typography.bodyMedium.copy(
                color = White,
                fontSize = 14.sp
            ),
            leadingIcon = {
                IconButton(
                    onClick = onVoiceClick,
                    modifier = Modifier.scale(pulseScale)
                ) {
                    Icon(
                        imageVector = Icons.Default.Mic,
                        contentDescription = stringResource(id = R.string.voice_input),
                        tint = if (isListening) NexusRed else Color.Gray
                    )
                }
            },
            trailingIcon = {
                IconButton(onClick = onSend) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.Send,
                        contentDescription = stringResource(id = R.string.run_command),
                        tint = NexusRed
                    )
                }
            },
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send),
            keyboardActions = KeyboardActions(onSend = { onSend() }),
            singleLine = true,
            shape = RoundedCornerShape(28.dp),
            colors = OutlinedTextFieldDefaults.colors(
                focusedBorderColor = NexusRed,
                unfocusedBorderColor = borderColor,
                cursorColor = NexusRed,
                focusedContainerColor = NexusCardDark,
                unfocusedContainerColor = NexusCardDark
            ),
            modifier = Modifier.fillMaxWidth()
        )
    }
}
