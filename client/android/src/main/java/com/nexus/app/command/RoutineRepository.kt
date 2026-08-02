package com.nexus.app.command

import com.nexus.app.data.local.NexusDatabase
import com.nexus.app.data.local.dao.CommandHistoryDao
import com.nexus.app.data.local.dao.RoutineSuggestionDao
import com.nexus.app.data.local.entity.CommandHistoryEntity
import com.nexus.app.data.local.entity.RoutineSuggestionEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import java.util.Calendar


/**
 * Detects recurring command patterns from on-device history and surfaces
 * them as suggestions. All processing stays local and deterministic.
 *
 * Safety features:
 * - Sensitive action types are never suggested.
 * - Suggestions are only surfaced when the current time is close to the
 *   routine hour.
 * - No command is ever executed automatically; the user must confirm.
 */
class RoutineRepository(private val database: NexusDatabase) {

    private val commandHistoryDao: CommandHistoryDao = database.commandHistoryDao()
    private val routineSuggestionDao: RoutineSuggestionDao = database.routineSuggestionDao()
    private val lastRefreshMs = java.util.concurrent.atomic.AtomicLong(0L)

    /**
     * Record a successfully executed command so routines can be detected.
     */
    suspend fun recordCommand(input: String, action: CommandAction) = withContext(Dispatchers.IO) {
        if (action !is CommandAction.SetAlarm) return@withContext
        val now = System.currentTimeMillis()
        val cal = Calendar.getInstance().apply { timeInMillis = now }
        val dayIndex = (now / (24L * 60 * 60 * 1000)).toInt()
        val entity = CommandHistoryEntity(
            input = input.trim().take(200),
            actionType = action.name,
            payload = payloadFor(action),
            timestamp = now,
            hourOfDay = cal.get(Calendar.HOUR_OF_DAY),
            dayIndex = dayIndex
        )
        commandHistoryDao.insert(entity)
    }

    /**
     * Recompute routines from recent history and persist them.
     * Throttled so it does not run more than once per minute.
     */
    suspend fun refreshRoutines(
        lookbackMs: Long = LOOKBACK_MS,
        minDays: Int = MIN_DAYS
    ) = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        if (now - lastRefreshMs.get() < MIN_REFRESH_INTERVAL_MS) return@withContext
        lastRefreshMs.set(now)

        val since = now - lookbackMs
        commandHistoryDao.pruneOld(since)

        val rows = commandHistoryDao.findRoutines(since, minDays)
        val filtered = rows.filter { it.actionType.isAllowedSuggestionType() }
        val activeKeys = filtered.map { it.actionType to it.payload }.toSet()
        val active = filtered.map { row ->
            RoutineSuggestionEntity(
                input = row.payload.ifBlank { row.actionType.replace('_', ' ').lowercase() },
                actionType = row.actionType,
                payload = row.payload,
                hourOfDay = row.hourOfDay,
                confidence = row.days.coerceAtLeast(1)
            )
        }

        // Remove suggestions whose pattern is no longer supported by recent history.
        val existing = routineSuggestionDao.getActiveSuggestionsSync(1000)
        existing.forEach { entity ->
            if ((entity.actionType to entity.payload) !in activeKeys) {
                routineSuggestionDao.deleteByAction(entity.actionType, entity.payload)
            }
        }

        active.forEach { suggestion ->
            routineSuggestionDao.upsert(suggestion)
        }
    }

    /**
     * Active suggestions for the current hour, limited to safe actions.
     */
    fun activeSuggestions(limit: Int = 5): Flow<List<RoutineSuggestion>> {
        return routineSuggestionDao.getActiveSuggestions(limit * 5).map { entities ->
            val now = Calendar.getInstance().get(Calendar.HOUR_OF_DAY)
            entities
                .filter { hourDistance(now, it.hourOfDay) <= 1 }
                .take(limit)
                .map { RoutineSuggestion.fromEntity(it) }
        }
    }

    suspend fun dismiss(suggestion: RoutineSuggestion) = withContext(Dispatchers.IO) {
        routineSuggestionDao.dismiss(suggestion.id)
    }

    suspend fun clearAll() = withContext(Dispatchers.IO) {
        routineSuggestionDao.clearAll()
    }

    companion object {
        const val LOOKBACK_MS = 30L * 24 * 60 * 60 * 1000
        const val MIN_DAYS = 3
        const val MIN_REFRESH_INTERVAL_MS = 60L * 1000

        private fun hourDistance(a: Int, b: Int): Int {
            val diff = kotlin.math.abs(a - b)
            return minOf(diff, 24 - diff)
        }
    }
}

/**
 * UI-facing model for a routine suggestion.
 */
data class RoutineSuggestion(
    val id: String,
    val input: String,
    val actionType: String,
    val payload: String,
    val hourOfDay: Int,
    val confidence: Int
) {
    val displayText: String
        get() = when (actionType) {
            "SET_ALARM" -> {
                val parts = payload.split(":")
                val hour = parts.getOrNull(0)?.toIntOrNull() ?: 7
                val minute = parts.getOrNull(1)?.toIntOrNull() ?: 0
                val suffix = if (hour < 12) "AM" else "PM"
                val displayHour = when {
                    hour == 0 -> 12
                    hour > 12 -> hour - 12
                    else -> hour
                }
                "Set alarm for %d:%02d %s".format(displayHour, minute, suffix)
            }
            else -> input.replace('_', ' ').replaceFirstChar { it.uppercaseChar() }
        }

    companion object {
        fun fromEntity(entity: RoutineSuggestionEntity): RoutineSuggestion = RoutineSuggestion(
            id = entity.id,
            input = entity.input,
            actionType = entity.actionType,
            payload = entity.payload,
            hourOfDay = entity.hourOfDay,
            confidence = entity.confidence
        )
    }
}

private fun String.isAllowedSuggestionType(): Boolean = this == "SET_ALARM"


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
        is CommandAction.PauseMedia -> action.query
        is CommandAction.PlayMediaApp -> "${action.query}|${action.appName}"
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
        is CommandAction.SmartHome -> "${action.device}|${action.operation}|${action.value.orEmpty()}"
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
