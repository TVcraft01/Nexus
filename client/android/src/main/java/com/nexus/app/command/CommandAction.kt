package com.nexus.app.command

import androidx.annotation.Keep

@Keep
sealed class CommandAction(val name: String) {
    data class OpenApp(val packageName: String) : CommandAction("OPEN_APP")
    data class OpenWebsite(val url: String) : CommandAction("OPEN_WEBSITE")
    data class WebSearch(val query: String) : CommandAction("WEB_SEARCH")
    data class ToggleWifi(val enable: Boolean) : CommandAction("TOGGLE_WIFI")
    data class ToggleBluetooth(val enable: Boolean) : CommandAction("TOGGLE_BLUETOOTH")
    data class SetBrightness(val level: Int) : CommandAction("SET_BRIGHTNESS")
    data class PlayMedia(val query: String) : CommandAction("PLAY_MEDIA")
    data class PauseMedia(val query: String) : CommandAction("PAUSE_MEDIA")
    data class PlayMediaApp(val query: String, val appName: String) : CommandAction("PLAY_MEDIA_APP")
    data class MediaControl(val command: String) : CommandAction("MEDIA_CONTROL")
    data class SetVolume(val percent: Int) : CommandAction("SET_VOLUME")
    data class AdjustVolume(val delta: Int) : CommandAction("ADJUST_VOLUME")
    data class MuteVolume(val dummy: Boolean = true) : CommandAction("MUTE_VOLUME")
    data class OpenSettings(val page: String) : CommandAction("OPEN_SETTINGS")
    data class MeshRelay(val payload: String) : CommandAction("MESH_RELAY")

    // Alexa-style local actions
    data class ToggleFlashlight(val enable: Boolean) : CommandAction("TOGGLE_FLASHLIGHT")
    data class SetTimer(val seconds: Int, val label: String? = null) : CommandAction("SET_TIMER")
    data class SetAlarm(val hour: Int, val minute: Int, val label: String? = null, val repeating: Boolean = false) : CommandAction("SET_ALARM")
    data class TakeNote(val content: String) : CommandAction("TAKE_NOTE")
    data class RollDice(val sides: Int = 6) : CommandAction("ROLL_DICE")
    data class FlipCoin(val dummy: Boolean = true) : CommandAction("FLIP_COIN")
    data class ToggleDnd(val enable: Boolean) : CommandAction("TOGGLE_DND")
    data class Navigate(val destination: String) : CommandAction("NAVIGATE")
    data class OpenCalendar(val dummy: Boolean = true) : CommandAction("OPEN_CALENDAR")
    data class Calculate(val expression: String) : CommandAction("CALCULATE")

    // Smart home, lists, reminders, knowledge, camera
    data class SmartHome(val device: String, val operation: String, val value: String?) : CommandAction("SMART_HOME")
    data class ListAction(val item: String, val listName: String) : CommandAction("LIST_ACTION")
    data class SetReminder(val task: String) : CommandAction("SET_REMINDER")
    data class SearchInfo(val query: String, val searchType: String) : CommandAction("SEARCH_INFO")
    data class OpenCamera(val isSelfie: Boolean) : CommandAction("OPEN_CAMERA")
    data class RecordVideo(val dummy: Boolean = true) : CommandAction("RECORD_VIDEO")

    // Communications
    data class CallContact(val contact: String) : CommandAction("CALL_CONTACT")
    data class SendText(val contact: String, val message: String?) : CommandAction("SEND_TEXT")
    data class SendEmail(val recipient: String) : CommandAction("SEND_EMAIL")

    // Timer / alarm cancellation
    data class CancelAlarmTimer(val dummy: Boolean = true) : CommandAction("CANCEL_ALARM_TIMER")

    // Info / data commands (phone + privacy-friendly APIs)
    data class GetTimeDate(val dummy: Boolean = true) : CommandAction("GET_TIME_DATE")
    data class GetBatteryStatus(val dummy: Boolean = true) : CommandAction("GET_BATTERY_STATUS")
    data class GetNextAlarm(val dummy: Boolean = true) : CommandAction("GET_NEXT_ALARM")
    data class GetJoke(val dummy: Boolean = true) : CommandAction("GET_JOKE")
    data class GetWeather(val dummy: Boolean = true) : CommandAction("GET_WEATHER")
    data class GetTodaySchedule(val dummy: Boolean = true) : CommandAction("GET_TODAY_SCHEDULE")

    data class Unknown(val raw: String) : CommandAction("UNKNOWN")
    data class Rejected(val reason: String) : CommandAction("REJECTED")
}

@Keep
data class MatchedRule(
    val pattern: String,
    val action: CommandAction,
    val source: RuleSource,
    val confidence: Float = 1.0f
)

@Keep
enum class RuleSource {
    BUILT_IN, USER
}

@Keep
enum class CommandStatus {
    VERIFIED_SUCCESS,   // Action completed and verified
    PENDING_HANDOFF,  // Action handed off to the OS/another app; user must finish it
    FAILED              // Action failed or was denied
}

@Keep
data class CommandResult(
    val success: Boolean,
    val message: String,
    val action: CommandAction,
    val status: CommandStatus = if (success) CommandStatus.VERIFIED_SUCCESS else CommandStatus.FAILED,
    val requiresInternChoice: Boolean = false,
    val choices: List<String> = emptyList(),
    val shouldRecordForRoutines: Boolean = false
)
