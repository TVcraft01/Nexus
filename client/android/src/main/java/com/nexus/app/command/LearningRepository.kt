package com.nexus.app.command

import android.content.Context
import android.util.Log
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/**
 * Lightweight, privacy-first learning repository.
 *
 * Stores successful command patterns on-device as JSON. When the user says
 * something the built-in rules don't recognize, the engine checks whether a
 * similar phrase has succeeded before and uses that action instead.
 */
class LearningRepository(context: Context) {

    data class LearnedCommand(
        val id: String = UUID.randomUUID().toString(),
        val input: String,
        val actionType: String,
        val payload: String,
        var successCount: Int = 1,
        var lastUsed: Long = System.currentTimeMillis()
    )

    private val appContext = context.applicationContext
    private val gson = Gson()
    private val jsonFile = File(appContext.filesDir, "learned_commands.json")

    private val learnedCommands = mutableListOf<LearnedCommand>()
    private val mutex = Mutex()

    init {
        load()
    }

    private fun load() {
        if (!jsonFile.exists()) return
        try {
            val type = object : TypeToken<List<LearnedCommand>>() {}.type
            val loaded: List<LearnedCommand> = gson.fromJson(jsonFile.readText(), type) ?: emptyList()
            learnedCommands.clear()
            learnedCommands.addAll(loaded)
        } catch (e: Exception) {
            Log.w("LearningRepository", "Failed to load learned commands", e)
        }
    }

    private fun save() {
        try {
            jsonFile.writeText(gson.toJson(learnedCommands))
        } catch (e: Exception) {
            Log.w("LearningRepository", "Failed to save learned commands", e)
        }
    }

    /**
     * Record that [input] successfully produced the given action.
     */
    suspend fun recordSuccess(input: String, action: CommandAction) = withContext(Dispatchers.IO) {
        mutex.withLock {
            val normalized = input.trim().lowercase()
            val existing = learnedCommands.find { it.input == normalized }
            if (existing != null) {
                existing.successCount++
                existing.lastUsed = System.currentTimeMillis()
            } else {
                learnedCommands.add(
                    LearnedCommand(
                        input = normalized,
                        actionType = action.name,
                        payload = payloadFor(action)
                    )
                )
            }
            save()
        }
    }

    /**
     * Find a previously successful action for a phrase similar to [input].
     * Returns null if nothing is similar enough.
     */
    suspend fun findSimilarAction(input: String, threshold: Double = 0.6): CommandAction? = withContext(Dispatchers.Default) {
        mutex.withLock {
            val normalized = input.trim().lowercase()
            val tokens = normalized.split(Regex("\\s+")).toSet()

            var best: LearnedCommand? = null
            var bestScore = 0.0

            learnedCommands.forEach { learned ->
                val learnedTokens = learned.input.split(Regex("\\s+")).toSet()
                val overlap = tokens.intersect(learnedTokens).size.toDouble()
                val union = tokens.union(learnedTokens).size.toDouble()
                if (union == 0.0) return@forEach
                val score = overlap / union
                if (score >= threshold && score > bestScore) {
                    bestScore = score
                    best = learned
                }
            }

            best?.let { reconstructAction(it.actionType, it.payload) }
        }
    }

    suspend fun getLearnedCount(): Int = mutex.withLock { learnedCommands.size }

    private fun payloadFor(action: CommandAction): String {
        return when (action) {
            is CommandAction.OpenApp -> action.packageName
            is CommandAction.OpenWebsite -> action.url
            is CommandAction.WebSearch -> action.query
            is CommandAction.ToggleWifi -> action.enable.toString()
            is CommandAction.ToggleBluetooth -> action.enable.toString()
            is CommandAction.SetBrightness -> action.level.toString()
            is CommandAction.SetVolume -> action.percent.toString()
            is CommandAction.AdjustVolume -> action.delta.toString()
            is CommandAction.MuteVolume -> ""
            is CommandAction.PlayMedia -> action.query
            is CommandAction.PlayMediaApp -> "${action.query}|${action.appName}"
            is CommandAction.PauseMedia -> action.query
            is CommandAction.MediaControl -> action.command
            is CommandAction.OpenSettings -> action.page
            is CommandAction.MeshRelay -> action.payload
            is CommandAction.ToggleFlashlight -> action.enable.toString()
            is CommandAction.SetTimer -> action.seconds.toString()
            is CommandAction.SetAlarm -> "${action.hour}:${action.minute}"
            is CommandAction.TakeNote -> action.content
            is CommandAction.RollDice -> action.sides.toString()
            is CommandAction.FlipCoin -> ""
            is CommandAction.ToggleDnd -> action.enable.toString()
            is CommandAction.Navigate -> action.destination
            is CommandAction.OpenCalendar -> ""
            is CommandAction.Calculate -> action.expression
            is CommandAction.SmartHome -> "${action.device}|${action.operation}|${action.value}"
            is CommandAction.ListAction -> "${action.item}|${action.listName}"
            is CommandAction.SetReminder -> action.task
            is CommandAction.SearchInfo -> "${action.query}|${action.searchType}"
            is CommandAction.OpenCamera -> action.isSelfie.toString()
            is CommandAction.RecordVideo -> ""
            is CommandAction.CallContact -> action.contact
            is CommandAction.SendText -> "${action.contact}|${action.message.orEmpty()}"
            is CommandAction.SendEmail -> action.recipient
            is CommandAction.CancelAlarmTimer -> ""
            is CommandAction.GetTimeDate -> ""
            is CommandAction.GetBatteryStatus -> ""
            is CommandAction.GetNextAlarm -> ""
            is CommandAction.GetJoke -> ""
            is CommandAction.GetWeather -> ""
            is CommandAction.GetTodaySchedule -> ""
            is CommandAction.Unknown -> action.raw
            is CommandAction.Rejected -> action.reason
        }
    }

    private fun reconstructAction(actionType: String, payload: String): CommandAction? {
        return try {
            when (actionType.uppercase()) {
                "OPEN_APP" -> CommandAction.OpenApp(payload)
                "OPEN_WEBSITE" -> CommandAction.OpenWebsite(payload)
                "WEB_SEARCH" -> CommandAction.WebSearch(payload)
                "TOGGLE_WIFI" -> CommandAction.ToggleWifi(payload.toBooleanStrictOrNull() ?: true)
                "TOGGLE_BLUETOOTH" -> CommandAction.ToggleBluetooth(payload.toBooleanStrictOrNull() ?: true)
                "SET_BRIGHTNESS" -> CommandAction.SetBrightness(payload.toIntOrNull() ?: 50)
                "SET_VOLUME" -> CommandAction.SetVolume(payload.toIntOrNull() ?: 50)
                "ADJUST_VOLUME" -> CommandAction.AdjustVolume(payload.toIntOrNull() ?: 0)
                "MUTE_VOLUME" -> CommandAction.MuteVolume()
                "PLAY_MEDIA" -> CommandAction.PlayMedia(payload)
                "PAUSE_MEDIA" -> CommandAction.PauseMedia(payload)
                "MEDIA_CONTROL" -> CommandAction.MediaControl(payload)
                "OPEN_SETTINGS" -> CommandAction.OpenSettings(payload)
                "MESH_RELAY" -> CommandAction.MeshRelay(payload)
                "TOGGLE_FLASHLIGHT" -> CommandAction.ToggleFlashlight(payload.toBooleanStrictOrNull() ?: true)
                "SET_TIMER" -> CommandAction.SetTimer(payload.toIntOrNull() ?: 60)
                "SET_ALARM" -> {
                    val parts = payload.split(":")
                    CommandAction.SetAlarm(
                        parts.getOrNull(0)?.toIntOrNull() ?: 7,
                        parts.getOrNull(1)?.toIntOrNull() ?: 0
                    )
                }
                "TAKE_NOTE" -> CommandAction.TakeNote(payload)
                "ROLL_DICE" -> CommandAction.RollDice(payload.toIntOrNull() ?: 6)
                "FLIP_COIN" -> CommandAction.FlipCoin()
                "TOGGLE_DND" -> CommandAction.ToggleDnd(payload.toBooleanStrictOrNull() ?: true)
                "NAVIGATE" -> CommandAction.Navigate(payload)
                "OPEN_CALENDAR" -> CommandAction.OpenCalendar()
                "CALCULATE" -> CommandAction.Calculate(payload)
                "SMART_HOME" -> {
                    val parts = payload.split("|", limit = 3)
                    CommandAction.SmartHome(
                        parts.getOrNull(0) ?: "",
                        parts.getOrNull(1) ?: "SET_STATE",
                        parts.getOrNull(2)
                    )
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
                "GET_TIME_DATE" -> CommandAction.GetTimeDate()
                "GET_BATTERY_STATUS" -> CommandAction.GetBatteryStatus()
                "GET_NEXT_ALARM" -> CommandAction.GetNextAlarm()
                "GET_JOKE" -> CommandAction.GetJoke()
                "GET_WEATHER" -> CommandAction.GetWeather()
                "GET_TODAY_SCHEDULE" -> CommandAction.GetTodaySchedule()
                else -> null
            }
        } catch (e: Exception) {
            Log.w("LearningRepository", "Failed to reconstruct action", e)
            null
        }
    }
}
