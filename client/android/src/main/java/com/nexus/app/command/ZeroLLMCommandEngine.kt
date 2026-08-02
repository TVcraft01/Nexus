package com.nexus.app.command

import android.annotation.SuppressLint
import android.app.AlarmManager
import android.app.NotificationManager
import android.content.Context
import android.provider.AlarmClock
import android.content.Intent
import android.content.pm.ResolveInfo
import android.hardware.camera2.CameraManager
import android.location.LocationManager
import android.app.SearchManager
import android.media.AudioManager
import android.net.Uri
import android.net.wifi.WifiManager
import android.provider.MediaStore
import android.bluetooth.BluetoothManager
import android.os.BatteryManager
import android.provider.CalendarContract
import android.provider.Settings
import androidx.core.content.ContextCompat
import androidx.core.content.PermissionChecker
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import com.nexus.app.data.local.dao.NoteDao
import com.nexus.app.data.local.entity.NoteEntity
import com.nexus.app.discovery.CapabilityRouter
import com.nexus.app.hardware.ExecutionMode
import com.nexus.app.hardware.HardwareManager
import java.util.regex.PatternSyntaxException

@SuppressLint("InlinedApi")
class ZeroLLMCommandEngine(
    context: Context,
    private val userRulesRepository: UserRulesRepository,
    private val hardwareManager: HardwareManager,
    private val noteDao: NoteDao,
    private val learningRepository: LearningRepository,
    private val capabilityRouter: CapabilityRouter? = null
) {
    private val appContext = context.applicationContext

    private val appAliases = mapOf(
        "google maps" to "com.google.android.apps.maps",
        "maps" to "com.google.android.apps.maps",
        "youtube" to "com.google.android.youtube",
        "chrome" to "com.android.chrome",
        "browser" to "com.android.chrome",
        "gmail" to "com.google.android.gm",
        "calendar" to "com.google.android.calendar",
        "clock" to "com.google.android.deskclock",
        "messages" to "com.google.android.apps.messaging",
        "photos" to "com.google.android.apps.photos",
        "drive" to "com.google.android.apps.docs",
        "keep" to "com.google.android.keep",
        "play store" to "com.android.vending",
        "contacts" to "com.google.android.contacts",
        "phone" to "com.google.android.dialer",
        "calculator" to "com.google.android.calculator",
        "settings" to "com.android.settings",
        "whatsapp" to "com.whatsapp",
        "telegram" to "org.telegram.messenger",
        "waze" to "com.waze"
    )

    companion object {
        // Deep link that opens the Deezer "Flow" personalized mix in the app.
        // Verified on-device: deezer://www.deezer.com/user/me/flow resolves to
        // Deezer's LauncherActivity; the https:// equivalent only opens a
        // browser, and bare "deezer://user/me/flow" matches only a widget.
        private const val DEEZER_FLOW_DEEP_LINK = "deezer://www.deezer.com/user/me/flow"

        val builtInRules: List<Pair<Regex, (MatchResult, String) -> CommandAction>> = listOf(
        // Network toggles
        "\\b(?:turn?\\s*on|enable|start)\\s+(?:wi[-]?fi|wifi|wireless)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.ToggleWifi(true) },
        "\\b(?:turn?\\s*off|disable|stop)\\s+(?:wi[-]?fi|wifi|wireless)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.ToggleWifi(false) },

        // Bluetooth toggles
        "\\b(?:turn?\\s*on|enable|start)\\s+(?:bluetooth|bt)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.ToggleBluetooth(true) },
        "\\b(?:turn?\\s*off|disable|stop)\\s+(?:bluetooth|bt)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.ToggleBluetooth(false) },

        // Brightness
        "\\b(?:set|change)\\s+brightness\\s+(?:to\\s+)?(\\d+)(?:%|\\s*percent)?\\b".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.SetBrightness(match.groupValues[1].toIntOrNull() ?: 50) },

        // Volume
        "\\b(?:set|change)\\s+volume\\s+(?:to\\s+)?(\\d+)(?:%|\\s*percent)?\\b".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.SetVolume(match.groupValues[1].toIntOrNull() ?: 50) },
        "\\b(?:turn\\s+)?(?:volume|sound)\\s+(?:up|louder|higher)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.AdjustVolume(+10) },
        "\\b(?:turn\\s+)?(?:volume|sound)\\s+(?:down|lower|softer|quieter)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.AdjustVolume(-10) },
        "\\b(?:mute|silence)\\s+(?:the\\s+)?(?:volume|sound)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.MuteVolume() },

        // Media controls (specific before generic play)
        "\\b(?:next|skip)\\s+(?:track|song)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.MediaControl("next") },
        "\\b(?:previous|last)\\s+(?:track|song)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.MediaControl("previous") },
        "\\brestart\\s+(?:track|song|music)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.MediaControl("restart") },
        "\\bwhat(?:['\\u0027]?s|\\s+is)?\\s+playing\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.MediaControl("info") },

        // Media playback by app
        "\\b(?:play|listen\\s+to)\\s+(.+?)\\s+(?:on|in)?\\s*(spotify|pandora|tunein|audible|kindle|youtube music|yt music|deezer|apple music|amazon music|tidal|soundcloud)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.PlayMediaApp(match.groupValues[1].trim(), match.groupValues[2].trim().lowercase()) },

        // Media playback (generic)
        "\\b(?:play|start)\\s+(.+)".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.PlayMedia(match.groupValues[1].trim()) },
        "\\b(?:pause|stop)\\s+(?:music|audio|track|song|playback)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.PauseMedia("") },
        "\\bchill\\s+tunes\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.PlayMedia("chill") },

        // Lights / IoT
        "\\b(?:kill|turn?\\s*off|switch\\s*off)\\s+(?:the\\s+)?lights\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.MeshRelay("iot:lights:off") },
        "\\b(?:turn?\\s*on|switch\\s*on)\\s+(?:the\\s+)?lights\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.MeshRelay("iot:lights:on") },

        // Open calendar explicitly before generic open-app
        "\\bopen\\s+calendar\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.OpenCalendar() },

        // Open app by name / package
        "\\bopen\\s+(?!settings\\b|prefs\\b|calendar\\b)(.+)".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.OpenApp(match.groupValues[1].trim()) },
        "\\bgo\\s+to\\s+(.+)".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.OpenWebsite(match.groupValues[1].trim()) },
        "\\b(?:search\\s+for|find)\\s+(.+)".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.WebSearch(match.groupValues[1].trim()) },

        // Settings
        "\\bopen\\s+(?:settings|prefs)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.OpenSettings("android.settings.SETTINGS") },

        // Mesh relay fallback
        "\\brelay\\s+(.+)".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.MeshRelay(match.groupValues[1].trim()) },

        // Alexa-style local commands
        // Flashlight
        "\\b(?:turn?\\s*on|enable|start)\\s+(?:flashlight|torch)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.ToggleFlashlight(true) },
        "\\b(?:turn?\\s*off|disable|stop)\\s+(?:flashlight|torch)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.ToggleFlashlight(false) },

        // Timer / alarm
        "\\b(?:set\\s+(?:a\\s+)?timer\\s+(?:for\\s+)?|timer\\s+|countdown\\s+)(\\d+)\\s*(seconds?|secs?|minutes?|mins?|hours?|hrs?)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ ->
                val value = match.groupValues[1].toIntOrNull() ?: 1
                val unit = match.groupValues[2].lowercase()
                val seconds = when {
                    unit.startsWith("hour") || unit.startsWith("hr") -> value * 3600
                    unit.startsWith("min") -> value * 60
                    else -> value
                }
                CommandAction.SetTimer(seconds)
            },
        "\\b(?:set\\s+(?:an?|the)?\\s*alarm\\s+(?:for\\s+)?|wake\\s+me\\s+(?:at\\s+)?|alarm\\s+)(\\d+)(?::(\\d+))?\\s*(am|pm)?\\b".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ ->
                val hour = match.groupValues[1].toIntOrNull() ?: 7
                val minute = match.groupValues[2].toIntOrNull() ?: 0
                val amPm = match.groupValues[3]
                val adjustedHour = when {
                    amPm.equals("pm", ignoreCase = true) && hour < 12 -> hour + 12
                    amPm.equals("am", ignoreCase = true) && hour == 12 -> 0
                    else -> hour
                }
                CommandAction.SetAlarm(adjustedHour, minute)
            },

        // Notes
        "\\b(?:take|make|save)\\s+a?\\s*note\\s+(?:that|to|of)?\\s*(.+)".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.TakeNote(match.groupValues[1].trim()) },

        // Utilities
        "\\b(?:roll|throw)\\s+(?:a\\s+)?dice\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.RollDice(6) },
        "\\bflip\\s+(?:a\\s+)?coin\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.FlipCoin() },
        "\\b(?:what(?:['\\u0027]?s?|\\s+is)?|calculate|compute)?\\s*(-?[0-9.]+)\\s*(times|multiplied by|x|divided by|over|plus|minus|[+\\-*/])\\s*(-?[0-9.]+)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ ->
                val opWord = match.groupValues[2].lowercase()
                val op = when (opWord) {
                    "times", "multiplied by", "x" -> "*"
                    "divided by", "over" -> "/"
                    "plus" -> "+"
                    "minus" -> "-"
                    else -> opWord
                }
                CommandAction.Calculate("${match.groupValues[1]}$op${match.groupValues[3]}")
            },
        "^(-?[0-9.]+)\\s*([+\\-*/])\\s*(-?[0-9.]+)$".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.Calculate(match.groupValues[0].trim()) },

        // Do not disturb
        "\\b(?:turn?\\s*on|enable|start)\\s+(?:do\\s+not\\s+disturb|dnd)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.ToggleDnd(true) },
        "\\b(?:turn?\\s*off|disable|stop)\\s+(?:do\\s+not\\s+disturb|dnd)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.ToggleDnd(false) },

        // Navigation — GREEDY capture so complex addresses ("221B Baker Street,
        // London") are never truncated; the (?!to\b) guard stops a bare
        // "navigate to" (common with voice pauses) from navigating to "to".
        "\\b(?:navigate|directions|take me|drive)\\s+(?:to\\s+)?(?!to\\b)(.+)\\s+(?:on|with|via|using)\\s+(waze|google maps|maps)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ ->
                CommandAction.Navigate(match.groupValues[1].trim(), match.groupValues[2].trim().lowercase())
            },
        "\\b(?:navigate|directions|take me|drive)\\s+(?:to\\s+)?(?!to\\b)(.+)".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.Navigate(match.groupValues[1].trim()) },

        // Info / data commands
        "\\b(?:what(?:['\\u0027]?s?|\\s+is)?\\s+(?:the\\s+)?(?:time(?:\\s+(?:is\\s+it|now))?|date|day(?:\\s+(?:is\\s+it|today))?)|tell\\s+me\\s+(?:the\\s+)?(?:time|date|day)|current\\s+(?:time|date))\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.GetTimeDate() },
        "\\b(?:battery|what['\u0027]?s\\s+my\\s+battery)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.GetBatteryStatus() },
        "\\bnext\\s+alarm\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.GetNextAlarm() },
        "\\btell\\s+me\\s+(?:a\\s+)?joke\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.GetJoke() },
        "\\b(?:(?:what|how)(?:['\\u0027]?s?|\\s+is)\\s+(?:the\\s+)?weather(?:\\s+like)?|weather(?:\\s+(?:forecast|report|today))?|is\\s+it\\s+(?:raining|gonna\\s+rain|going\\s+to\\s+rain))\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.GetWeather() },
        "\\b(?:what['\\u0027]?s\\s+(?:on\\s+my\\s+)?(?:calendar|schedule)(?:\\s+today)?|my\\s+schedule(?:\\s+today)?|show\\s+(?:my\\s+)?(?:calendar|schedule))\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.GetTodaySchedule() },

        // Smart home
        "\\b(?:dim|set|change)\\s+(?:the\\s+)?(.+?)\\s+(?:to\\s+)?(\\d+%|red|blue|green|warm|cool)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.SmartHome(match.groupValues[1].trim(), "SET_STATE", match.groupValues[2].trim()) },
        "\\b(?:set|change)\\s+(?:the\\s+)?thermostat\\s+(?:to\\s+)?(\\d+)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.SmartHome("thermostat", "SET_TEMP", match.groupValues[1].trim()) },
        "\\b(?:activate|start)\\s+(?:the\\s+)?(.+?)\\s+scene\\b".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.SmartHome("scene", "ACTIVATE", match.groupValues[1].trim()) },

        // Lists and reminders
        "\\b(?:add|put)\\s+(.+?)\\s+(?:to|on)\\s+(?:my\\s+)?(shopping|to[- ]?do)\\s+list\\b".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.ListAction(match.groupValues[1].trim(), match.groupValues[2].trim()) },
        "\\bremind\\s+me\\s+(?:to\\s+)?(.+)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.SetReminder(match.groupValues[1].trim()) },

        // Knowledge
        "\\b(?:define|what is the definition of)\\s+(.+)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.SearchInfo(match.groupValues[1].trim(), "Define") },
        "\\bhow\\s+do\\s+you\\s+spell\\s+(.+)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.SearchInfo(match.groupValues[1].trim(), "Spell") },

        // Camera
        "\\btake\\s+a\\s+(selfie|picture|photo)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.OpenCamera(match.groupValues[1].equals("selfie", ignoreCase = true)) },

        // Record video
        "\\b(?:record|shoot|take)\\s+(?:a\\s+)?video\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.RecordVideo() },

        // Sleep timer (play for N minutes then pause)
        "\\b(?:sleep\\s+timer|(?:stop|pause)\\s+(?:music|audio|playback)?\\s*(?:in|after))\\s+(?:for\\s+)?(\\d+)\\s*(minutes?|mins?|hours?|hrs?)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ ->
                val value = match.groupValues[1].toIntOrNull() ?: 30
                val unit = match.groupValues[2].lowercase()
                val seconds = when {
                    unit.startsWith("hour") || unit.startsWith("hr") -> value * 3600
                    else -> value * 60
                }
                CommandAction.SleepTimer(seconds)
            },
        "\\bplay\\s+.+?\\s+for\\s+(\\d+)\\s*(minutes?|mins?|hours?|hrs?)\\b".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ ->
                val value = match.groupValues[1].toIntOrNull() ?: 30
                val unit = match.groupValues[2].lowercase()
                val seconds = when {
                    unit.startsWith("hour") || unit.startsWith("hr") -> value * 3600
                    else -> value * 60
                }
                CommandAction.SleepTimer(seconds)
            },

        // Cancel timer/alarm
        "\\bcancel\\s+(?:my\\s+|the\\s+|a\\s+)?(?:timer|alarm)s?\\b".toRegex(RegexOption.IGNORE_CASE) to
            { _, _ -> CommandAction.CancelAlarmTimer() },

        // Communications
        "\\b(?:call|phone|dial)\\s+(.+)".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.CallContact(match.groupValues[1].trim()) },
        "\\b(?:text|sms|message)\\s+(.+?)(?:\\s+(?:saying|that)\\s+(.+))?$".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.SendText(match.groupValues[1].trim(), match.groupValues[2].takeIf { it.isNotBlank() }) },
        "\\b(?:email|send\\s+an\\s+email\\s+to)\\s+(.+)".toRegex(RegexOption.IGNORE_CASE) to
            { match, _ -> CommandAction.SendEmail(match.groupValues[1].trim()) }
    )

    /**
     * Extract representative keyword phrases from the built-in regex rules.
     * These are fed into the Vosk grammar so the small model only recognizes
     * command-like utterances — not random background speech.
     *
     * Each rule contributes a handful of short example phrases that Vosk's
     * grammar mode can match against. We extract the literal words from the
     * regex patterns (stripping capture groups and quantifiers) rather than
     * hardcoding a separate list.
     */
    fun extractCommandKeywords(): List<String> {
        // Empty by design. The system starts knowing nothing.
        // All knowledge comes from: skills (downloaded), learned commands,
        // user rules, and the adaptive engine. The base is empty —
        // the user fills it in.
        return emptyList()
    }

    /**
     * Pure function to map text to a CommandAction independently of Android Context.
     */
    fun parseCommand(input: String): CommandAction? {
        val sanitized = input.trim()
        if (sanitized.isBlank()) return null
        return builtInRules.asSequence()
            .mapNotNull { (regex, factory) ->
                regex.find(sanitized)?.let { match ->
                    try {
                        factory(match, sanitized)
                    } catch (_: Exception) {
                        null
                    }
                }
            }
            .firstOrNull()
    }

    /**
     * True when the query asks for Deezer's personalized "Flow" mix
     * ("flow" / "my flow"). These must open the Flow deep link directly —
     * a MEDIA_PLAY_FROM_SEARCH for "flow" makes Deezer play a track that is
     * literally named "flow" instead of the mix.
     */
    fun isFlowQuery(query: String): Boolean {
        // Strip trailing punctuation — voice recognition often appends
        // ".", ",", etc. to "my flow." which would otherwise miss.
        val q = query.trim().lowercase().trimEnd('.', ',', '!', '?', ';', ':')
        return q == "flow" || q == "my flow"
    }

    } // end companion object

    suspend fun executeCommand(input: String): CommandResult {
        val sanitized = input.trim()
        if (sanitized.isBlank()) {
            return CommandResult(false, "Empty command.", CommandAction.Unknown(""))
        }

        // --- Compound command support ---
        // "play jazz and set a sleep timer for 30 minutes" → split into 2 commands
        val parts = CompoundCommandParser.split(sanitized)
        if (parts.size > 1) {
            val results = mutableListOf<CommandResult>()
            for (part in parts) {
                results.add(executeSingleCommand(part))
            }
            val messages = results.joinToString("\n") { "• ${it.message}" }
            val allSuccess = results.all { it.success || !it.requiresInternChoice }
            return CommandResult(
                allSuccess,
                "Done (${parts.size} actions):\n$messages",
                results.last().action
            )
        }

        return executeSingleCommand(sanitized)
    }

    private suspend fun executeSingleCommand(sanitized: String): CommandResult {
        // --- Skill command matching ---
        // Downloaded skills provide command patterns that are matched before
        // built-in rules. The system starts empty and earns knowledge from skills.
        val skillAction = matchSkillCommand(sanitized)
        if (skillAction != null) {
            val result = performAction(skillAction)
            if (result.success) {
                learningRepository.recordSuccess(sanitized, skillAction)
            }
            return result
        }

        val userRules = userRulesRepository.getEnabledRules()

        val userMatch = userRules.asSequence()
            .sortedByDescending { it.priority }
            .mapNotNull { rule ->
                try {
                    val regex = Regex(rule.pattern, RegexOption.IGNORE_CASE)
                    regex.find(sanitized)?.let { rule to it }
                } catch (_: PatternSyntaxException) {
                    null
                }
            }
            .firstOrNull()

        if (userMatch != null) {
            val (rule, match) = userMatch
            val action = parseUserAction(rule, match)
            val result = performAction(action)
            if (result.success) {
                learningRepository.recordSuccess(sanitized, action)
            }
            return result.copy(
                message = "User rule matched '${rule.pattern}': ${result.message}"
            )
        }

        val builtInAction = parseCommand(sanitized)
        if (builtInAction != null) {
            val result = performAction(builtInAction)
            if (result.success) {
                learningRepository.recordSuccess(sanitized, builtInAction)
            }
            return result
        }

        // Try to learn from previous successful commands.
        val learnedAction = learningRepository.findSimilarAction(sanitized)
        if (learnedAction != null) {
            val result = performAction(learnedAction)
            if (result.success) {
                learningRepository.recordSuccess(sanitized, learnedAction)
            }
            return result.copy(
                message = "Learned: ${result.message}"
            )
        }


        return CommandResult(
            false,
            "I don't know how to handle '$sanitized'.",
            CommandAction.Unknown(sanitized),
            requiresInternChoice = true,
            choices = listOf("Teach Nexus", "Not now")
        )
    }

    /**
     * Match user input against skill commands from installed skills.
     * Returns a CommandAction if a skill pattern matches, null otherwise.
     */
    private fun matchSkillCommand(input: String): CommandAction? {
        val appContext = appContext as? android.app.Application ?: return null
        val skillRegistry = (appContext as? com.nexus.app.NexusApplication)?.skillRegistry ?: return null
        val commands = skillRegistry.getAllCommands()
        for (cmd in commands) {
            if (cmd.pattern.isBlank()) continue
            try {
                val regex = Regex(cmd.pattern, RegexOption.IGNORE_CASE)
                val match = regex.find(input) ?: continue
                // Map skill action type to CommandAction
                val payload = if (match.groupValues.size > 1) {
                    match.groupValues[1].trim()
                } else {
                    cmd.payloadTemplate
                }
                return skillPayloadToAction(cmd.actionType, payload)
            } catch (_: Exception) { }
        }
        return null
    }

    /**
     * Convert a skill action type string + payload into a concrete CommandAction.
     */
    private fun skillPayloadToAction(actionType: String, payload: String): CommandAction? {
        return when (actionType.uppercase()) {
            "PLAY_MEDIA" -> CommandAction.PlayMedia(payload)
            "PLAY_MEDIA_APP" -> {
                val parts = payload.split("|", limit = 2)
                CommandAction.PlayMediaApp(parts.getOrNull(0) ?: payload, parts.getOrNull(1) ?: "")
            }
            "PAUSE_MEDIA" -> CommandAction.PauseMedia(payload)
            "MEDIA_CONTROL" -> CommandAction.MediaControl(payload)
            "OPEN_APP" -> CommandAction.OpenApp(payload)
            "OPEN_SETTINGS" -> CommandAction.OpenSettings(payload)
            "OPEN_WEBSITE" -> CommandAction.OpenWebsite(payload)
            "WEB_SEARCH" -> CommandAction.WebSearch(payload)
            "TOGGLE_WIFI" -> CommandAction.ToggleWifi(payload.toBooleanStrictOrNull() ?: true)
            "TOGGLE_BLUETOOTH" -> CommandAction.ToggleBluetooth(payload.toBooleanStrictOrNull() ?: true)
            "TOGGLE_FLASHLIGHT" -> CommandAction.ToggleFlashlight(payload.toBooleanStrictOrNull() ?: true)
            "SET_VOLUME" -> CommandAction.SetVolume(payload.toIntOrNull() ?: 50)
            "ADJUST_VOLUME" -> CommandAction.AdjustVolume(payload.toIntOrNull() ?: 0)
            "MUTE_VOLUME" -> CommandAction.MuteVolume()
            "SET_TIMER" -> CommandAction.SetTimer(payload.toIntOrNull() ?: 60)
            "SET_ALARM" -> {
                val parts = payload.split(":")
                CommandAction.SetAlarm(parts.getOrNull(0)?.toIntOrNull() ?: 7, parts.getOrNull(1)?.toIntOrNull() ?: 0)
            }
            "SLEEP_TIMER" -> CommandAction.SleepTimer(payload.toIntOrNull() ?: 1800)
            "NAVIGATE" -> CommandAction.Navigate(payload)
            "TAKE_NOTE" -> CommandAction.TakeNote(payload)
            "ROLL_DICE" -> CommandAction.RollDice(payload.toIntOrNull() ?: 6)
            "FLIP_COIN" -> CommandAction.FlipCoin()
            "TOGGLE_DND" -> CommandAction.ToggleDnd(payload.toBooleanStrictOrNull() ?: true)
            "CALL_CONTACT" -> CommandAction.CallContact(payload)
            "SEND_TEXT" -> {
                val parts = payload.split("|", limit = 2)
                CommandAction.SendText(parts.getOrNull(0) ?: payload, parts.getOrNull(1)?.takeIf { it.isNotBlank() })
            }
            "GET_TIME_DATE" -> CommandAction.GetTimeDate()
            "GET_WEATHER" -> CommandAction.GetWeather()
            "GET_BATTERY_STATUS" -> CommandAction.GetBatteryStatus()
            "GET_JOKE" -> CommandAction.GetJoke()
            "MESH_RELAY" -> CommandAction.MeshRelay(payload)
            else -> null
        }
    }

    private fun parseUserAction(rule: UserDialectRule, match: MatchResult): CommandAction {
        val payload = match.groupValues.getOrNull(1) ?: rule.payload
        return when (rule.actionType.uppercase()) {
            "OPEN_APP" -> CommandAction.OpenApp(payload)
            "TOGGLE_WIFI" -> CommandAction.ToggleWifi(payload.toBooleanStrictOrNull() ?: true)
            "TOGGLE_BLUETOOTH" -> CommandAction.ToggleBluetooth(payload.toBooleanStrictOrNull() ?: true)
            "SET_BRIGHTNESS" -> CommandAction.SetBrightness(payload.toIntOrNull() ?: 50)
            "SET_VOLUME" -> CommandAction.SetVolume(payload.toIntOrNull() ?: 50)
            "ADJUST_VOLUME" -> CommandAction.AdjustVolume(payload.toIntOrNull() ?: 0)
            "MUTE_VOLUME" -> CommandAction.MuteVolume()
            "PLAY_MEDIA" -> CommandAction.PlayMedia(payload)
            "PLAY_MEDIA_APP" -> {
                val parts = payload.split("|", limit = 2)
                CommandAction.PlayMediaApp(parts.getOrNull(0) ?: payload, parts.getOrNull(1) ?: "")
            }
            "MEDIA_CONTROL" -> CommandAction.MediaControl(payload)
            "PAUSE_MEDIA" -> CommandAction.PauseMedia(payload)
            "OPEN_SETTINGS" -> CommandAction.OpenSettings(payload)
            "MESH_RELAY" -> CommandAction.MeshRelay(payload)
            "TOGGLE_FLASHLIGHT" -> CommandAction.ToggleFlashlight(payload.toBooleanStrictOrNull() ?: true)
            "SET_TIMER" -> CommandAction.SetTimer(payload.toIntOrNull() ?: 60)
            "SET_ALARM" -> {
                val parts = payload.split(":")
                CommandAction.SetAlarm(parts.getOrNull(0)?.toIntOrNull() ?: 7, parts.getOrNull(1)?.toIntOrNull() ?: 0)
            }
            "SMART_HOME" -> {
                val parts = payload.split("|", limit = 3)
                CommandAction.SmartHome(parts.getOrNull(0) ?: "", parts.getOrNull(1) ?: "SET_STATE", parts.getOrNull(2))
            }
            "LIST_ACTION" -> {
                val parts = payload.split("|", limit = 2)
                CommandAction.ListAction(parts.getOrNull(0) ?: payload, parts.getOrNull(1) ?: "todo")
            }
            "SET_REMINDER" -> CommandAction.SetReminder(payload)
            "SEARCH_INFO" -> {
                val parts = payload.split("|", limit = 2)
                CommandAction.SearchInfo(parts.getOrNull(0) ?: payload, parts.getOrNull(1) ?: "Define")
            }
            "OPEN_CAMERA" -> CommandAction.OpenCamera(payload.toBooleanStrictOrNull() ?: false)
            "RECORD_VIDEO" -> CommandAction.RecordVideo()
            "CALL_CONTACT" -> CommandAction.CallContact(payload)
            "SEND_TEXT" -> {
                val parts = payload.split("|", limit = 2)
                CommandAction.SendText(parts.getOrNull(0) ?: payload, parts.getOrNull(1))
            }
            "SEND_EMAIL" -> CommandAction.SendEmail(payload)
            "CANCEL_ALARM_TIMER" -> CommandAction.CancelAlarmTimer()
            "TAKE_NOTE" -> CommandAction.TakeNote(payload)
            "ROLL_DICE" -> CommandAction.RollDice(payload.toIntOrNull() ?: 6)
            "FLIP_COIN" -> CommandAction.FlipCoin()
            "TOGGLE_DND" -> CommandAction.ToggleDnd(payload.toBooleanStrictOrNull() ?: true)
            "NAVIGATE" -> {
                val parts = payload.split("|", limit = 2)
                CommandAction.Navigate(parts[0], parts.getOrNull(1)?.takeIf { it.isNotBlank() })
            }
            "OPEN_CALENDAR" -> CommandAction.OpenCalendar()
            "CALCULATE" -> CommandAction.Calculate(payload)
            "GET_TIME_DATE" -> CommandAction.GetTimeDate()
            "GET_BATTERY_STATUS" -> CommandAction.GetBatteryStatus()
            "GET_NEXT_ALARM" -> CommandAction.GetNextAlarm()
            "GET_JOKE" -> CommandAction.GetJoke()
            "GET_WEATHER" -> CommandAction.GetWeather()
            "GET_TODAY_SCHEDULE" -> CommandAction.GetTodaySchedule()
            else -> CommandAction.Unknown(rule.actionType)
        }
    }

    suspend fun performAction(action: CommandAction): CommandResult {
        return when (action) {
            is CommandAction.ToggleWifi -> toggleWifi(action.enable)
            is CommandAction.ToggleBluetooth -> toggleBluetooth(action.enable)
            is CommandAction.SetBrightness -> setBrightness(action.level)
            is CommandAction.SetVolume -> setVolume(action.percent)
            is CommandAction.AdjustVolume -> adjustVolume(action.delta)
            is CommandAction.MuteVolume -> muteVolume()
            is CommandAction.PlayMedia -> playMedia(action.query)
            is CommandAction.PlayMediaApp -> playMediaApp(action.query, action.appName)
            is CommandAction.PauseMedia -> pauseMedia()
            is CommandAction.MediaControl -> handleMediaControl(action.command)
            is CommandAction.OpenApp -> openApp(action.packageName)
            is CommandAction.OpenWebsite -> openWebsite(action.url)
            is CommandAction.WebSearch -> webSearch(action.query)
            is CommandAction.OpenSettings -> openSettings(action.page)
            is CommandAction.MeshRelay -> meshRelay(action.payload)
            is CommandAction.ToggleFlashlight -> toggleFlashlight(action.enable)
            is CommandAction.SetTimer -> setTimer(action.seconds)
            is CommandAction.SetAlarm -> setAlarm(action.hour, action.minute)
            is CommandAction.TakeNote -> takeNote(action.content)
            is CommandAction.RollDice -> rollDice(action.sides)
            is CommandAction.FlipCoin -> flipCoin()
            is CommandAction.ToggleDnd -> toggleDnd(action.enable)
            is CommandAction.Navigate -> navigate(action.destination, action.preferredApp)
            is CommandAction.OpenCalendar -> openCalendar()
            is CommandAction.SmartHome -> handleSmartHome(action.device, action.operation, action.value)
            is CommandAction.ListAction -> addToList(action.item, action.listName)
            is CommandAction.SetReminder -> setReminder(action.task)
            is CommandAction.SearchInfo -> searchKnowledge(action.query, action.searchType)
            is CommandAction.OpenCamera -> openCamera(action.isSelfie)
            is CommandAction.RecordVideo -> recordVideo()
            is CommandAction.CallContact -> actionCallDialer(action.contact)
            is CommandAction.SendText -> actionSendText(action.contact, action.message)
            is CommandAction.SendEmail -> actionSendEmail(action.recipient)
            is CommandAction.SleepTimer -> sleepTimer(action.durationSeconds)
            is CommandAction.CancelAlarmTimer -> actionCancelAlarmTimer()
            is CommandAction.Calculate -> calculate(action.expression)
            is CommandAction.GetTimeDate -> getTimeDate()
            is CommandAction.GetBatteryStatus -> getBatteryStatus()
            is CommandAction.GetNextAlarm -> getNextAlarm()
            is CommandAction.GetJoke -> getJoke()
            is CommandAction.GetWeather -> getWeather()
            is CommandAction.GetTodaySchedule -> getTodaySchedule()
            is CommandAction.Unknown -> CommandResult(false, "Unknown command action.", action)
            is CommandAction.Rejected -> CommandResult(false, action.reason, action)
        }
    }

    private fun toggleWifi(enable: Boolean): CommandResult {
        return try {
            val wifiManager = appContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
                ?: return CommandResult(false, "WiFi manager unavailable.", CommandAction.ToggleWifi(enable), requiresInternChoice = true, choices = listOf("Retry", "Cancel"))

            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
                return openWifiSettingsPanel(enable)
            }

            @Suppress("DEPRECATION")
            wifiManager.isWifiEnabled = enable
            val actual = wifiManager.isWifiEnabled
            return if (actual == enable) {
                CommandResult(true, "WiFi ${if (enable) "enabled" else "disabled"}.", CommandAction.ToggleWifi(enable), CommandStatus.VERIFIED_SUCCESS)
            } else {
                CommandResult(false, "WiFi state could not be verified.", CommandAction.ToggleWifi(enable), CommandStatus.FAILED)
            }
        } catch (se: SecurityException) {
            CommandResult(
                false,
                "Permission denied toggling WiFi.",
                CommandAction.ToggleWifi(enable),
                requiresInternChoice = true,
                choices = listOf("Grant Permission", "Cancel")
            )
        }
    }

    private fun openWifiSettingsPanel(enable: Boolean): CommandResult {
        return try {
            val panelIntent = Intent(Settings.Panel.ACTION_WIFI).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (panelIntent.resolveActivity(appContext.packageManager) != null) {
                appContext.startActivity(panelIntent)
                CommandResult(false, "WiFi panel opened. Please toggle WiFi manually.", CommandAction.ToggleWifi(enable), CommandStatus.PENDING_HANDOFF)
            } else {
                throw IllegalStateException("WiFi panel unavailable")
            }
        } catch (e: Exception) {
            val settingsIntent = Intent(Settings.ACTION_WIFI_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            appContext.startActivity(settingsIntent)
            CommandResult(false, "WiFi settings opened. Please toggle WiFi manually.", CommandAction.ToggleWifi(enable), CommandStatus.PENDING_HANDOFF)
        }
    }

    private fun toggleBluetooth(enable: Boolean): CommandResult {
        return try {
            val bluetoothManager = appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            val adapter = bluetoothManager?.adapter
                ?: return CommandResult(false, "Bluetooth not supported.", CommandAction.ToggleBluetooth(enable))
            val accepted = if (enable) adapter.enable() else adapter.disable()
            return if (accepted) {
                CommandResult(true, "Bluetooth ${if (enable) "enabled" else "disabled"}.", CommandAction.ToggleBluetooth(enable), CommandStatus.VERIFIED_SUCCESS)
            } else {
                CommandResult(false, "Bluetooth toggle was rejected by the system.", CommandAction.ToggleBluetooth(enable), CommandStatus.FAILED)
            }
        } catch (se: SecurityException) {
            CommandResult(
                false,
                "Permission denied toggling Bluetooth.",
                CommandAction.ToggleBluetooth(enable),
                requiresInternChoice = true,
                choices = listOf("Grant Permission", "Cancel")
            )
        }
    }

    private fun setBrightness(level: Int): CommandResult {
        val safeLevel = level.coerceIn(0, 100)
        return try {
            val value = (safeLevel / 100.0 * 255).toInt()
            Settings.System.putInt(appContext.contentResolver, Settings.System.SCREEN_BRIGHTNESS, value)
            val actual = Settings.System.getInt(appContext.contentResolver, Settings.System.SCREEN_BRIGHTNESS)
            return if (actual == value) {
                CommandResult(true, "Brightness set to $safeLevel%.", CommandAction.SetBrightness(safeLevel), CommandStatus.VERIFIED_SUCCESS)
            } else {
                CommandResult(false, "Failed to set brightness.", CommandAction.SetBrightness(safeLevel), CommandStatus.FAILED)
            }
        } catch (se: SecurityException) {
            val manageIntent = Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS).apply {
                data = android.net.Uri.parse("package:${appContext.packageName}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (manageIntent.resolveActivity(appContext.packageManager) != null) {
                appContext.startActivity(manageIntent)
            }
            CommandResult(
                false,
                "Permission required to write system settings. Opening app settings...",
                CommandAction.SetBrightness(safeLevel),
                requiresInternChoice = true,
                choices = listOf("Open Settings", "Cancel")
            )
        }
    }

    private fun setVolume(percent: Int): CommandResult {
        val audioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            ?: return CommandResult(false, "Audio manager unavailable.", CommandAction.SetVolume(percent))
        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val target = (percent / 100.0 * max).toInt().coerceIn(0, max)
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, target, AudioManager.FLAG_SHOW_UI)
        val actual = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        return if (actual == target) {
            CommandResult(true, "Media volume set to $percent%.", CommandAction.SetVolume(percent), CommandStatus.VERIFIED_SUCCESS)
        } else {
            CommandResult(false, "Failed to set volume.", CommandAction.SetVolume(percent), CommandStatus.FAILED)
        }
    }

    private fun adjustVolume(delta: Int): CommandResult {
        val audioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            ?: return CommandResult(false, "Audio manager unavailable.", CommandAction.AdjustVolume(delta))
        val max = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
        val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        val target = (current + (delta * max / 100)).coerceIn(0, max)
        audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, target, AudioManager.FLAG_SHOW_UI)
        val actual = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
        return if (actual == target) {
            CommandResult(true, "Volume adjusted.", CommandAction.AdjustVolume(delta), CommandStatus.VERIFIED_SUCCESS)
        } else {
            CommandResult(false, "Failed to adjust volume.", CommandAction.AdjustVolume(delta), CommandStatus.FAILED)
        }
    }

    private fun muteVolume(): CommandResult {
        val audioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            ?: return CommandResult(false, "Audio manager unavailable.", CommandAction.MuteVolume())
        audioManager.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_MUTE, 0)
        return CommandResult(true, "Volume muted.", CommandAction.MuteVolume(), CommandStatus.VERIFIED_SUCCESS)
    }

    /**
     * Open the Deezer "Flow" mix via its app deep link. Returns a result if
     * Deezer can handle it, otherwise null so the caller falls back to a
     * normal media search (e.g. when Deezer isn't installed).
     */
    private fun startDeezerFlow(action: CommandAction): CommandResult? {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(DEEZER_FLOW_DEEP_LINK)).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (intent.resolveActivity(appContext.packageManager) != null) {
            try {
                appContext.startActivity(intent)
                CommandResult(false, "Starting your Deezer Flow mix.", action, CommandStatus.PENDING_HANDOFF)
            } catch (_: Exception) {
                null
            }
        } else {
            null
        }
    }

    private suspend fun playMedia(query: String): CommandResult {
        // "Play my flow" must open the Deezer Flow mix, not search for a
        // track literally named "flow". Bypass the router/search entirely.
        if (isFlowQuery(query)) {
            startDeezerFlow(CommandAction.PlayMedia(query))?.let { return it }
        }

        // 1. Route through the capability index first: "play X" goes to the
        //    best discovered media app, with no hardcoded player names.
        capabilityRouter?.let { router ->
            val routed = router.routeMediaPlayback(query)
            if (routed.success) {
                return CommandResult(false, routed.message, CommandAction.PlayMedia(query), CommandStatus.PENDING_HANDOFF)
            }
        }
        // Try the standard "play from search" intent so installed players
        // (Spotify, Deezer, YouTube Music, etc.) can handle the request.
        val mediaIntent = Intent(MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH).apply {
            putExtra(SearchManager.QUERY, query)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (mediaIntent.resolveActivity(appContext.packageManager) != null) {
            appContext.startActivity(mediaIntent)
            CommandResult(false, "Choose a player to play: $query", CommandAction.PlayMedia(query), CommandStatus.PENDING_HANDOFF)
        } else {
            // Fallback to a YouTube search.
            val ytIntent = Intent(Intent.ACTION_VIEW).apply {
                data = Uri.parse("https://www.youtube.com/results?search_query=${Uri.encode(query)}")
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (ytIntent.resolveActivity(appContext.packageManager) != null) {
                appContext.startActivity(ytIntent)
                CommandResult(false, "Opened YouTube search for: $query", CommandAction.PlayMedia(query), CommandStatus.PENDING_HANDOFF)
            } else {
                CommandResult(false, "No app can handle media playback.", CommandAction.PlayMedia(query))
            }
        }
    }

    private fun pauseMedia(): CommandResult {
        val audioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as? AudioManager
            ?: return CommandResult(false, "Audio manager unavailable.", CommandAction.PauseMedia(""))
        if (audioManager.isMusicActive) {
            val intent = Intent("com.android.music.musicservicecommand").apply {
                putExtra("command", "pause")
            }
            appContext.sendBroadcast(intent)
            return CommandResult(false, "Pause broadcast sent.", CommandAction.PauseMedia(""), CommandStatus.PENDING_HANDOFF)
        }
        return CommandResult(false, "No active media.", CommandAction.PauseMedia(""))
    }

    private suspend fun openApp(query: String): CommandResult {
        // 1. Route through the capability index first: "open X" resolves to
        //    the best discovered app by label/package — no hardcoded names.
        capabilityRouter?.let { router ->
            val routed = router.routeOpenApp(query)
            if (routed.success) {
                return CommandResult(false, routed.message, CommandAction.OpenApp(query), CommandStatus.PENDING_HANDOFF)
            }
        }

        val pm = appContext.packageManager

        // Try direct package name first.
        pm.getLaunchIntentForPackage(query)?.let { launchIntent ->
            launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            appContext.startActivity(launchIntent)
            return CommandResult(false, "Opened $query.", CommandAction.OpenApp(query), CommandStatus.PENDING_HANDOFF)
        }

        // Try well-known aliases (e.g., "google maps", "youtube").
        appAliases[query.lowercase().trim()]?.let { packageName ->
            pm.getLaunchIntentForPackage(packageName)?.let { launchIntent ->
                launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                appContext.startActivity(launchIntent)
                return CommandResult(false, "Opened $query.", CommandAction.OpenApp(query), CommandStatus.PENDING_HANDOFF)
            }
        }

        // Tokenize the query so "google maps" matches Maps by matching
        // the words "google" and "maps" against the label or package name.
        val queryTokens = query.lowercase()
            .split("[^a-z0-9]+".toRegex())
            .filter { it.isNotBlank() }
            .distinct()
        if (queryTokens.isEmpty()) {
            return CommandResult(false, "App $query not installed.", CommandAction.OpenApp(query), requiresInternChoice = true, choices = listOf("Install", "Cancel"))
        }

        val installed = pm.queryIntentActivities(
            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER),
            0
        )

        val alphaNumRegex = "[^a-z0-9]+".toRegex()

        data class AppCandidate(
            val resolveInfo: ResolveInfo,
            val label: String,
            val packageName: String,
            val matchedTokens: Int,
            val wordBoundaryMatches: Int
        )

        val candidates = installed.mapNotNull { resolveInfo ->
            val label = resolveInfo.loadLabel(pm)?.toString()?.lowercase() ?: ""
            val labelTokens = label.split(alphaNumRegex).filter { it.isNotBlank() }
            val pkg = resolveInfo.activityInfo?.packageName?.lowercase() ?: ""
            val pkgTokens = pkg.split(alphaNumRegex).filter { it.isNotBlank() }

            var matched = 0
            var wordBoundaries = 0
            for (token in queryTokens) {
                val inLabel = label.contains(token)
                val inPkg = pkg.contains(token)
                if (inLabel || inPkg) {
                    matched++
                    if (labelTokens.any { it == token } ||
                        labelTokens.any { it.startsWith(token) } ||
                        pkgTokens.any { it == token }
                    ) {
                        wordBoundaries++
                    }
                }
            }
            if (matched == 0) null
            else AppCandidate(resolveInfo, label, pkg, matched, wordBoundaries)
        }
            .sortedWith(
                compareByDescending<AppCandidate> { it.matchedTokens == queryTokens.size }
                    .thenByDescending { it.matchedTokens }
                    .thenByDescending { it.wordBoundaryMatches }
                    .thenBy { (it.label + it.packageName).length }
            )

        candidates.firstOrNull()?.let { candidate ->
            val packageName = candidate.resolveInfo.activityInfo.packageName
            val intent = pm.getLaunchIntentForPackage(packageName)
                ?: return CommandResult(false, "Could not launch $query.", CommandAction.OpenApp(query), requiresInternChoice = true, choices = listOf("Cancel"))
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            appContext.startActivity(intent)
            return CommandResult(false, "Opened ${candidate.resolveInfo.loadLabel(pm)}.", CommandAction.OpenApp(query), CommandStatus.PENDING_HANDOFF)
        }

        return CommandResult(false, "App $query not installed.", CommandAction.OpenApp(query), requiresInternChoice = true, choices = listOf("Install", "Cancel"))
    }

    private fun openWebsite(url: String): CommandResult {
        val fullUrl = when {
            url.startsWith("http://") || url.startsWith("https://") -> url
            else -> "https://$url"
        }
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(fullUrl)).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (intent.resolveActivity(appContext.packageManager) != null) {
            appContext.startActivity(intent)
            CommandResult(false, "Opening $fullUrl.", CommandAction.OpenWebsite(url), CommandStatus.PENDING_HANDOFF)
        } else {
            CommandResult(false, "No browser found.", CommandAction.OpenWebsite(url))
        }
    }

    private fun webSearch(query: String): CommandResult {
        val intent = Intent(Intent.ACTION_WEB_SEARCH).apply {
            putExtra(SearchManager.QUERY, query)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (intent.resolveActivity(appContext.packageManager) != null) {
            appContext.startActivity(intent)
            CommandResult(false, "Searching for: $query", CommandAction.WebSearch(query), CommandStatus.PENDING_HANDOFF)
        } else {
            CommandResult(false, "No search app found.", CommandAction.WebSearch(query))
        }
    }

    private fun openSettings(page: String): CommandResult {
        val intent = Intent(page).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (intent.resolveActivity(appContext.packageManager) != null) {
            appContext.startActivity(intent)
            CommandResult(false, "Opened settings.", CommandAction.OpenSettings(page), CommandStatus.PENDING_HANDOFF)
        } else {
            CommandResult(false, "Cannot open settings page.", CommandAction.OpenSettings(page))
        }
    }

    private fun meshRelay(payload: String): CommandResult {
        if (hardwareManager.determineExecutionMode() == ExecutionMode.THIN_NODE) {
            return CommandResult(
                true,
                "Mesh relay queued: $payload (thin-node relay only).",
                CommandAction.MeshRelay(payload)
            )
        }
        return CommandResult(true, "Mesh relay broadcast: $payload", CommandAction.MeshRelay(payload))
    }

    // --- Alexa-style local helpers ---

    private fun toggleFlashlight(enable: Boolean): CommandResult {
        val cameraManager = appContext.getSystemService(Context.CAMERA_SERVICE) as? CameraManager
            ?: return CommandResult(false, "Camera service unavailable.", CommandAction.ToggleFlashlight(enable))
        return try {
            val cameraId = cameraManager.cameraIdList.firstOrNull()
                ?: return CommandResult(false, "No camera found.", CommandAction.ToggleFlashlight(enable))
            cameraManager.setTorchMode(cameraId, enable)
            CommandResult(true, "Flashlight ${if (enable) "on" else "off"}.", CommandAction.ToggleFlashlight(enable))
        } catch (e: Exception) {
            CommandResult(false, "Failed to toggle flashlight: ${e.message}", CommandAction.ToggleFlashlight(enable))
        }
    }

    private fun setTimer(seconds: Int): CommandResult {
        val intent = Intent(AlarmClock.ACTION_SET_TIMER).apply {
            putExtra(AlarmClock.EXTRA_LENGTH, seconds)
            putExtra(AlarmClock.EXTRA_SKIP_UI, true)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (intent.resolveActivity(appContext.packageManager) != null) {
            appContext.startActivity(intent)
            CommandResult(false, "Clock app opened to set timer.", CommandAction.SetTimer(seconds), CommandStatus.PENDING_HANDOFF)
        } else {
            CommandResult(false, "No clock app available for timer.", CommandAction.SetTimer(seconds))
        }
    }

    private fun setAlarm(hour: Int, minute: Int): CommandResult {
        val intent = Intent(AlarmClock.ACTION_SET_ALARM).apply {
            putExtra(AlarmClock.EXTRA_HOUR, hour)
            putExtra(AlarmClock.EXTRA_MINUTES, minute)
            putExtra(AlarmClock.EXTRA_SKIP_UI, false)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (intent.resolveActivity(appContext.packageManager) != null) {
            appContext.startActivity(intent)
            CommandResult(
                false,
                "Clock app opened to set alarm.",
                CommandAction.SetAlarm(hour, minute),
                CommandStatus.PENDING_HANDOFF,
                shouldRecordForRoutines = true
            )
        } else {
            CommandResult(false, "No clock app available for alarm.", CommandAction.SetAlarm(hour, minute))
        }
    }

    private suspend fun takeNote(content: String): CommandResult {
        return try {
            noteDao.insert(NoteEntity(content = content))
            CommandResult(true, "Note saved: $content", CommandAction.TakeNote(content))
        } catch (e: Exception) {
            CommandResult(false, "Failed to save note: ${e.message}", CommandAction.TakeNote(content))
        }
    }

    private fun rollDice(sides: Int): CommandResult {
        val safeSides = sides.coerceAtLeast(2)
        val result = (1..safeSides).random()
        return CommandResult(true, "You rolled a $result (d$sides).", CommandAction.RollDice(safeSides))
    }

    private fun flipCoin(): CommandResult {
        val result = if (java.util.Random().nextBoolean()) "Heads" else "Tails"
        return CommandResult(true, "The coin landed on $result.", CommandAction.FlipCoin())
    }

    private fun toggleDnd(enable: Boolean): CommandResult {
        val notificationManager = appContext.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
            ?: return CommandResult(false, "Notification service unavailable.", CommandAction.ToggleDnd(enable))

        if (!notificationManager.isNotificationPolicyAccessGranted) {
            return CommandResult(
                false,
                "Do Not Disturb requires notification policy access.",
                CommandAction.ToggleDnd(enable),
                requiresInternChoice = true,
                choices = listOf("Grant DND Permission", "Cancel")
            )
        }

        val filter = if (enable) {
            NotificationManager.INTERRUPTION_FILTER_NONE
        } else {
            NotificationManager.INTERRUPTION_FILTER_ALL
        }
        notificationManager.setInterruptionFilter(filter)
        val actual = notificationManager.currentInterruptionFilter
        return if ((enable && actual == NotificationManager.INTERRUPTION_FILTER_NONE) || (!enable && actual == NotificationManager.INTERRUPTION_FILTER_ALL)) {
            CommandResult(true, "Do Not Disturb ${if (enable) "enabled" else "disabled"}.", CommandAction.ToggleDnd(enable), CommandStatus.VERIFIED_SUCCESS)
        } else {
            CommandResult(false, "Do Not Disturb state could not be verified.", CommandAction.ToggleDnd(enable), CommandStatus.FAILED)
        }
    }

    private suspend fun navigate(destination: String, preferredApp: String? = null): CommandResult {
        val dest = destination.trim()
        if (dest.isEmpty() || dest.equals("to", ignoreCase = true)) {
            return CommandResult(false, "I didn't catch the destination. Please say the place you want to go to.", CommandAction.Navigate(dest, preferredApp))
        }

        // 1. The user EXPLICITLY named an app ("navigate to X on waze") — honor
        //    it before the capability router can silently pick a different app.
        preferredApp?.let { app ->
            val uri = when (app.lowercase()) {
                "waze" -> "waze://?q=${Uri.encode(dest)}"
                "google.navigation", "google maps", "maps" -> "google.navigation:q=${Uri.encode(dest)}"
                else -> null
            }
            if (uri != null) {
                val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uri)).apply {
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                }
                if (intent.resolveActivity(appContext.packageManager) != null) {
                    appContext.startActivity(intent)
                    return CommandResult(
                        false,
                        "Navigation started to $dest on ${if (app.equals("waze", ignoreCase = true)) "Waze" else "Google Maps"}.",
                        CommandAction.Navigate(dest, preferredApp),
                        CommandStatus.PENDING_HANDOFF
                    )
                }
            }
        }

        // 2. Route through the capability index: whatever nav app is installed.
        capabilityRouter?.let { router ->
            val routed = router.routeNavigation(dest, preferredApp)
            if (routed.success) {
                return CommandResult(false, routed.message, CommandAction.Navigate(dest, preferredApp), CommandStatus.PENDING_HANDOFF)
            }
        }

        // 3. Generic fallback: Waze → Google Maps (dedup via string URIs)
        val encoded = Uri.encode(dest)
        val wazeUri = "waze://?q=$encoded"
        val mapsUri = "google.navigation:q=$encoded"
        val appLabel = mapOf(wazeUri to "Waze", mapsUri to "Google Maps")

        val urisToTry = linkedSetOf(wazeUri, mapsUri)
        for (uriStr in urisToTry) {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uriStr)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            if (intent.resolveActivity(appContext.packageManager) != null) {
                appContext.startActivity(intent)
                return CommandResult(
                    false,
                    "Navigation started to $dest on ${appLabel[uriStr] ?: "navigation app"}.",
                    CommandAction.Navigate(dest, preferredApp),
                    CommandStatus.PENDING_HANDOFF
                )
            }
        }

        return CommandResult(false, "No navigation app available (try installing Waze or Google Maps).", CommandAction.Navigate(dest, preferredApp))
    }

    private fun openCalendar(): CommandResult {
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse("content://com.android.calendar/time/")).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (intent.resolveActivity(appContext.packageManager) != null) {
            appContext.startActivity(intent)
            CommandResult(false, "Opening calendar.", CommandAction.OpenCalendar(), CommandStatus.PENDING_HANDOFF)
        } else {
            CommandResult(false, "No calendar app available.", CommandAction.OpenCalendar())
        }
    }

    private fun calculate(expression: String): CommandResult {
        val result = evaluateExpression(expression)
        return if (result != null) {
            CommandResult(true, "$expression = $result", CommandAction.Calculate(expression))
        } else {
            CommandResult(false, "Could not calculate $expression.", CommandAction.Calculate(expression))
        }
    }

    private fun evaluateExpression(expression: String): Double? {
        val sanitized = expression.replace(" ", "")
        val regex = "(-?[0-9.]+)([+\\-*/])(-?[0-9.]+)".toRegex()
        val match = regex.find(sanitized) ?: return null
        val a = match.groupValues[1].toDoubleOrNull() ?: return null
        val op = match.groupValues[2]
        val b = match.groupValues[3].toDoubleOrNull() ?: return null
        return when (op) {
            "+" -> a + b
            "-" -> a - b
            "*" -> a * b
            "/" -> if (b == 0.0) null else a / b
            else -> null
        }
    }

    // --- Info / data helpers ---

    private fun getTimeDate(): CommandResult {
        val now = java.util.Calendar.getInstance().time
        val time = java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault()).format(now)
        val date = java.text.SimpleDateFormat("EEEE, d MMMM yyyy", java.util.Locale.getDefault()).format(now)
        return CommandResult(true, "It is $time on $date.", CommandAction.GetTimeDate())
    }

    private fun getBatteryStatus(): CommandResult {
        val batteryManager = appContext.getSystemService(Context.BATTERY_SERVICE) as? BatteryManager
            ?: return CommandResult(false, "Battery service unavailable.", CommandAction.GetBatteryStatus())
        val level = batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        val status = batteryManager.getIntProperty(BatteryManager.BATTERY_PROPERTY_STATUS)
        val statusText = when (status) {
            BatteryManager.BATTERY_STATUS_CHARGING -> "charging"
            BatteryManager.BATTERY_STATUS_FULL -> "full"
            BatteryManager.BATTERY_STATUS_DISCHARGING -> "discharging"
            BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "not charging"
            else -> "unknown"
        }
        return CommandResult(true, "Battery is at $level% and $statusText.", CommandAction.GetBatteryStatus())
    }

    private fun getNextAlarm(): CommandResult {
        val alarmManager = appContext.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
            ?: return CommandResult(false, "Alarm service unavailable.", CommandAction.GetNextAlarm())
        val alarmClock = alarmManager.nextAlarmClock
        return if (alarmClock != null) {
            val time = java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault())
                .format(java.util.Date(alarmClock.triggerTime))
            CommandResult(true, "Your next alarm is at $time.", CommandAction.GetNextAlarm())
        } else {
            CommandResult(true, "No upcoming alarms.", CommandAction.GetNextAlarm())
        }
    }

    private suspend fun getJoke(): CommandResult {
        return try {
            val jokeText = withContext(Dispatchers.IO) {
                val url = java.net.URL("https://v2.jokeapi.dev/joke/Any?safe-mode&format=txt")
                url.openConnection()
                    .apply { setRequestProperty("Accept", "text/plain") }
                    .getInputStream()
                    .bufferedReader()
                    .readText()
                    .trim()
            }
            CommandResult(true, jokeText.ifBlank { "No joke returned." }, CommandAction.GetJoke())
        } catch (e: Exception) {
            CommandResult(false, "Could not fetch a joke: ${e.message}", CommandAction.GetJoke())
        }
    }

    private suspend fun getWeather(): CommandResult {
        val locationGranted = PermissionChecker.checkSelfPermission(
            appContext,
            android.Manifest.permission.ACCESS_FINE_LOCATION
        ) == PermissionChecker.PERMISSION_GRANTED

        if (!locationGranted) {
            return CommandResult(
                false,
                "Weather needs location permission.",
                CommandAction.GetWeather(),
                requiresInternChoice = true,
                choices = listOf("Grant Location Permission", "Cancel")
            )
        }

        val locationManager = appContext.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
            ?: return CommandResult(false, "Location service unavailable.", CommandAction.GetWeather())

        val location = try {
            locationManager.getLastKnownLocation(LocationManager.NETWORK_PROVIDER)
                ?: locationManager.getLastKnownLocation(LocationManager.GPS_PROVIDER)
        } catch (e: SecurityException) {
            null
        }

        if (location == null) {
            return CommandResult(false, "Could not get location. Make sure location is enabled.", CommandAction.GetWeather())
        }

        return try {
            val urlString = "https://api.open-meteo.com/v1/forecast?latitude=${location.latitude}&longitude=${location.longitude}&current_weather=true"
            val response = withContext(Dispatchers.IO) {
                java.net.URL(urlString)
                    .openConnection()
                    .apply { setRequestProperty("Accept", "application/json") }
                    .getInputStream()
                    .bufferedReader()
                    .readText()
            }
            val json = JSONObject(response)
            val current = json.getJSONObject("current_weather")
            val tempC = current.getDouble("temperature")
            val code = current.getInt("weathercode")
            val condition = weatherCodeToDescription(code)
            CommandResult(true, "Current weather: %.1f°C, %s.".format(tempC, condition), CommandAction.GetWeather())
        } catch (e: Exception) {
            CommandResult(false, "Could not fetch weather: ${e.message}", CommandAction.GetWeather())
        }
    }

    private fun weatherCodeToDescription(code: Int): String {
        return when (code) {
            0 -> "clear sky"
            1, 2, 3 -> "partly cloudy"
            45, 48 -> "foggy"
            51, 53, 55 -> "drizzle"
            61, 63, 65 -> "rainy"
            71, 73, 75 -> "snow"
            95, 96, 99 -> "thunderstorm"
            else -> "unknown"
        }
    }

    // --- New Alexa-style local helpers ---

    private suspend fun playMediaApp(query: String, appName: String): CommandResult {
        // "Play my flow on deezer" must open the Flow mix directly.
        if (appName.equals("deezer", ignoreCase = true) && isFlowQuery(query)) {
            startDeezerFlow(CommandAction.PlayMediaApp(query, appName))?.let { return it }
        }

        // 1. Route through the capability index first: the named app is found
        //    by label in the discovered index (Spotify, Deezer, whatever is
        //    actually installed) instead of a hardcoded package list.
        capabilityRouter?.let { router ->
            val routed = router.routeMediaPlayback(query, appName)
            if (routed.success) {
                return CommandResult(false, routed.message, CommandAction.PlayMediaApp(query, appName), CommandStatus.PENDING_HANDOFF)
            }
        }

        val intent = Intent(MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH).apply {
            putExtra(SearchManager.QUERY, query)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val targetPkg = when (appName.lowercase()) {
                "spotify" -> "com.spotify.music"
                "pandora" -> "com.pandora.android"
                "audible" -> "com.audible.application"
                "kindle" -> "com.amazon.kindle"
                "youtube music", "yt music" -> "com.google.android.apps.youtube.music"
                "deezer" -> "deezer.android.app"
                "apple music" -> "com.apple.android.music"
                "amazon music" -> "com.amazon.mp3"
                "tidal" -> "com.aspiro.tidal"
                "soundcloud" -> "com.soundcloud.android"
                else -> null
            }
            targetPkg?.let { setPackage(it) }
        }
        return if (intent.resolveActivity(appContext.packageManager) != null) {
            appContext.startActivity(intent)
            CommandResult(false, "Playing $query on $appName.", CommandAction.PlayMediaApp(query, appName), CommandStatus.PENDING_HANDOFF)
        } else {
            CommandResult(false, "$appName is not installed or cannot handle this.", CommandAction.PlayMediaApp(query, appName))
        }
    }

    private fun handleMediaControl(command: String): CommandResult {
        if (command == "info") {
            return CommandResult(false, "Cannot read active media without Notification Listener permission.", CommandAction.MediaControl(command))
        }
        val intent = Intent("com.android.music.musicservicecommand").apply {
            putExtra("command", command)
        }
        appContext.sendBroadcast(intent)
        return CommandResult(false, "Media control '$command' sent.", CommandAction.MediaControl(command), CommandStatus.PENDING_HANDOFF)
    }

    private fun handleSmartHome(device: String, operation: String, value: String?): CommandResult {
        val meshPayload = "iot:$device:$operation:$value"
        val relayResult = meshRelay(meshPayload)
        val intent = appContext.packageManager.getLaunchIntentForPackage("com.google.android.apps.chromecast.app")?.apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (intent != null) {
            appContext.startActivity(intent)
            CommandResult(false, "${relayResult.message} Opening Home app to finish.", CommandAction.SmartHome(device, operation, value), CommandStatus.PENDING_HANDOFF)
        } else {
            CommandResult(false, "${relayResult.message} No Home app installed.", CommandAction.SmartHome(device, operation, value), CommandStatus.PENDING_HANDOFF)
        }
    }

    private fun addToList(item: String, listName: String): CommandResult {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TITLE, "$listName List")
            putExtra(Intent.EXTRA_TEXT, item)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        appContext.startActivity(Intent.createChooser(intent, "Add to list").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        return CommandResult(false, "Select an app to save your list item.", CommandAction.ListAction(item, listName), CommandStatus.PENDING_HANDOFF)
    }

    private fun setReminder(task: String): CommandResult {
        val intent = Intent(Intent.ACTION_INSERT).apply {
            data = CalendarContract.Events.CONTENT_URI
            putExtra(CalendarContract.Events.TITLE, task)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (intent.resolveActivity(appContext.packageManager) != null) {
            appContext.startActivity(intent)
            CommandResult(false, "Opening calendar to save reminder.", CommandAction.SetReminder(task), CommandStatus.PENDING_HANDOFF)
        } else {
            CommandResult(false, "No calendar app available for reminders.", CommandAction.SetReminder(task))
        }
    }

    private fun searchKnowledge(query: String, type: String): CommandResult {
        val searchString = when (type) {
            "Spell" -> "spell $query"
            else -> "define $query"
        }
        val intent = Intent(Intent.ACTION_WEB_SEARCH).apply {
            putExtra(SearchManager.QUERY, searchString)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (intent.resolveActivity(appContext.packageManager) != null) {
            appContext.startActivity(intent)
            CommandResult(false, "Looking up: $searchString", CommandAction.SearchInfo(query, type), CommandStatus.PENDING_HANDOFF)
        } else {
            CommandResult(false, "No search app available.", CommandAction.SearchInfo(query, type))
        }
    }

    private fun openCamera(isSelfie: Boolean): CommandResult {
        val intent = Intent(MediaStore.INTENT_ACTION_STILL_IMAGE_CAMERA).apply {
            if (isSelfie) {
                putExtra("android.intent.extras.CAMERA_FACING", 1)
                putExtra("android.intent.extras.LENS_FACING_FRONT", 1)
                putExtra("USE_FRONT_CAMERA", true)
            }
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (intent.resolveActivity(appContext.packageManager) != null) {
            appContext.startActivity(intent)
            CommandResult(false, "Camera opened.", CommandAction.OpenCamera(isSelfie), CommandStatus.PENDING_HANDOFF)
        } else {
            CommandResult(false, "No camera app found.", CommandAction.OpenCamera(isSelfie))
        }
    }

    private fun recordVideo(): CommandResult {
        val intent = Intent(MediaStore.INTENT_ACTION_VIDEO_CAMERA).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (intent.resolveActivity(appContext.packageManager) != null) {
            appContext.startActivity(intent)
            CommandResult(false, "Video camera opened.", CommandAction.RecordVideo(), CommandStatus.PENDING_HANDOFF)
        } else {
            CommandResult(false, "No video camera app found.", CommandAction.RecordVideo())
        }
    }

    private fun actionCallDialer(contact: String): CommandResult {
        val intent = Intent(Intent.ACTION_DIAL, Uri.parse("tel:${Uri.encode(contact)}")).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (intent.resolveActivity(appContext.packageManager) != null) {
            appContext.startActivity(intent)
            CommandResult(false, "Opening dialer for $contact...", CommandAction.CallContact(contact), CommandStatus.PENDING_HANDOFF)
        } else {
            CommandResult(false, "No dialer app found.", CommandAction.CallContact(contact))
        }
    }

    private fun actionSendText(contact: String, message: String?): CommandResult {
        val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("smsto:${Uri.encode(contact)}")).apply {
            message?.let { putExtra("sms_body", it) }
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (intent.resolveActivity(appContext.packageManager) != null) {
            appContext.startActivity(intent)
            CommandResult(false, "Opening messenger...", CommandAction.SendText(contact, message), CommandStatus.PENDING_HANDOFF)
        } else {
            CommandResult(false, "No messaging app found.", CommandAction.SendText(contact, message))
        }
    }

    private fun actionSendEmail(recipient: String): CommandResult {
        val intent = Intent(Intent.ACTION_SENDTO, Uri.parse("mailto:${Uri.encode(recipient)}")).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (intent.resolveActivity(appContext.packageManager) != null) {
            appContext.startActivity(intent)
            CommandResult(false, "Opening email...", CommandAction.SendEmail(recipient), CommandStatus.PENDING_HANDOFF)
        } else {
            CommandResult(false, "No email app found.", CommandAction.SendEmail(recipient))
        }
    }

    private fun sleepTimer(durationSeconds: Int): CommandResult {
        // Start playing music, then schedule a pause after the duration
        val mediaIntent = Intent(MediaStore.INTENT_ACTION_MEDIA_PLAY_FROM_SEARCH).apply {
            putExtra(SearchManager.QUERY, "chill")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (mediaIntent.resolveActivity(appContext.packageManager) != null) {
            appContext.startActivity(mediaIntent)
        }
        val handler = android.os.Handler(appContext.mainLooper)
        handler.postDelayed({
            try {
                val intent = Intent("com.android.music.musicservicecommand").apply {
                    putExtra("command", "pause")
                }
                appContext.sendBroadcast(intent)
            } catch (_: Exception) { }
        }, durationSeconds * 1000L)
        val mins = durationSeconds / 60
        return CommandResult(
            true,
            "Sleep timer set for $mins minutes. Music will pause automatically.",
            CommandAction.SleepTimer(durationSeconds)
        )
    }

    private fun actionCancelAlarmTimer(): CommandResult {
        if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.Q) {
            val fallback = Intent(AlarmClock.ACTION_SHOW_ALARMS).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
            return if (fallback.resolveActivity(appContext.packageManager) != null) {
                appContext.startActivity(fallback)
                CommandResult(false, "Opening clock app.", CommandAction.CancelAlarmTimer(), CommandStatus.PENDING_HANDOFF)
            } else {
                CommandResult(false, "No clock app available.", CommandAction.CancelAlarmTimer())
            }
        }
        val intent = Intent(AlarmClock.ACTION_DISMISS_ALARM).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return if (intent.resolveActivity(appContext.packageManager) != null) {
            appContext.startActivity(intent)
            CommandResult(false, "Opening clock app...", CommandAction.CancelAlarmTimer(), CommandStatus.PENDING_HANDOFF)
        } else {
            CommandResult(false, "No clock app to cancel timers.", CommandAction.CancelAlarmTimer())
        }
    }

    private fun getTodaySchedule(): CommandResult {
        val calendarGranted = PermissionChecker.checkSelfPermission(
            appContext,
            android.Manifest.permission.READ_CALENDAR
        ) == PermissionChecker.PERMISSION_GRANTED

        if (!calendarGranted) {
            return CommandResult(
                false,
                "Calendar access requires permission.",
                CommandAction.GetTodaySchedule(),
                requiresInternChoice = true,
                choices = listOf("Grant Calendar Permission", "Cancel")
            )
        }

        return try {
            val now = java.util.Calendar.getInstance()
            val start = now.timeInMillis
            now.set(java.util.Calendar.HOUR_OF_DAY, 23)
            now.set(java.util.Calendar.MINUTE, 59)
            now.set(java.util.Calendar.SECOND, 59)
            val end = now.timeInMillis

            val uri = CalendarContract.Instances.CONTENT_URI.buildUpon()
                .appendPath(start.toString())
                .appendPath(end.toString())
                .build()

            val events = mutableListOf<String>()
            appContext.contentResolver.query(
                uri,
                arrayOf(CalendarContract.Instances.TITLE, CalendarContract.Instances.BEGIN, CalendarContract.Instances.END),
                null,
                null,
                "${CalendarContract.Instances.BEGIN} ASC"
            )?.use { cursor ->
                val titleIndex = cursor.getColumnIndex(CalendarContract.Instances.TITLE)
                val beginIndex = cursor.getColumnIndex(CalendarContract.Instances.BEGIN)
                while (cursor.moveToNext()) {
                    val title = if (titleIndex >= 0) cursor.getString(titleIndex) ?: "(No title)" else "(No title)"
                    val begin = if (beginIndex >= 0) cursor.getLong(beginIndex) else 0L
                    val time = java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault()).format(java.util.Date(begin))
                    events.add("$time $title")
                }
            }

            val message = if (events.isEmpty()) "No events on your calendar today." else events.joinToString("\n")
            CommandResult(true, message, CommandAction.GetTodaySchedule())
        } catch (e: Exception) {
            CommandResult(false, "Could not read calendar: ${e.message}", CommandAction.GetTodaySchedule())
        }
    }
}
