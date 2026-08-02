package com.nexus.app.brain

import android.content.Context
import com.nexus.app.command.CommandAction
import com.nexus.app.command.CommandResult
import com.nexus.app.command.ZeroLLMCommandEngine
import com.nexus.app.data.local.NexusDatabase
import com.nexus.app.data.local.entity.ChatMessageEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

class NexusBrain(
    private val context: Context,
    private val commandEngine: ZeroLLMCommandEngine,
    private val database: NexusDatabase
) {

    private val dao = database.chatMessageDao()
    private var pendingAction: CommandAction? = null

    suspend fun chat(userText: String, backend: DiscoveredBackend?): BrainResponse = withContext(Dispatchers.IO) {
        if (backend == null) {
            return@withContext BrainResponse(
                text = "I can't find a local LLM server. Please start Ollama, LM Studio, or llama.cpp first."
            )
        }

        insert(ChatMessage(role = "user", content = userText))

        val messages = buildMessages()
        val raw = callLlm(backend, messages) ?: return@withContext BrainResponse(
            text = "I'm having trouble reaching the local LLM right now."
        )

        val parsed = parseResponse(raw)
        if (parsed == null) {
            insert(ChatMessage(role = "assistant", content = raw))
            return@withContext BrainResponse(text = raw)
        }

        val type = parsed.optString("type", "chat")
        val content = parsed.optString("content", raw)

        if (type == "command") {
            return@withContext handleCommand(parsed, backend)
        }

        insert(ChatMessage(role = "assistant", content = content))
        BrainResponse(text = content)
    }

    suspend fun confirmPendingCommand(backend: DiscoveredBackend): BrainResponse = withContext(Dispatchers.IO) {
        val action = pendingAction ?: return@withContext BrainResponse(text = "No pending command to confirm.")
        pendingAction = null
        val result = commandEngine.performAction(action)
        insert(ChatMessage(role = "system", content = "Command result: ${result.message}"))
        val summary = summarizeResult(backend, result)
        insert(ChatMessage(role = "assistant", content = summary))
        BrainResponse(text = summary, action = action, actionResult = result, requiresConfirmation = false)
    }

    suspend fun loadHistory(): List<ChatMessage> = withContext(Dispatchers.IO) {
        dao.getRecentMessagesSync(200).map { entity ->
            ChatMessage(
                id = entity.id,
                timestamp = entity.timestamp,
                role = entity.role,
                content = entity.content,
                actionExecuted = entity.actionExecuted,
                requiresConfirmation = entity.requiresConfirmation
            )
        }
    }

    suspend fun clearHistory() = withContext(Dispatchers.IO) {
        dao.clearAll()
        pendingAction = null
    }

    private suspend fun insert(message: ChatMessage) {
        dao.insert(
            ChatMessageEntity(
                id = message.id,
                timestamp = message.timestamp,
                role = message.role,
                content = message.content,
                actionExecuted = message.actionExecuted,
                requiresConfirmation = message.requiresConfirmation
            )
        )
    }

    private suspend fun buildMessages(): List<JSONObject> {
        val messages = mutableListOf<JSONObject>()
        val prompt = systemPrompt()
        messages.add(JSONObject().apply {
            put("role", "system")
            put("content", prompt)
        })

        val recent = dao.getRecentMessagesSync(200)
        val budget = (MAX_CONTEXT_CHARS - prompt.length).coerceAtLeast(0)
        val selected = mutableListOf<ChatMessageEntity>()
        var used = 0
        for (msg in recent.reversed()) {
            if (used + msg.content.length > budget) break
            selected.add(msg)
            used += msg.content.length
        }

        for (msg in selected.reversed()) {
            messages.add(JSONObject().apply {
                put("role", msg.role)
                put("content", msg.content)
            })
        }
        return messages
    }

    private fun callLlm(backend: DiscoveredBackend, messages: List<JSONObject>): String? {
        var connection: HttpURLConnection? = null
        return try {
            val url = URL(backend.backend.chatEndpoint)
            connection = url.openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.connectTimeout = 5000
            connection.readTimeout = 30000
            connection.setRequestProperty("Content-Type", "application/json")
            connection.setRequestProperty("Accept", "application/json")

            val payload = JSONObject().apply {
                put("model", backend.selectedModel ?: backend.models.firstOrNull() ?: "local")
                put("messages", JSONArray(messages))
                put("temperature", 0.3)
                put("max_tokens", 512)
            }

            connection.outputStream.use { os ->
                os.write(payload.toString().toByteArray(Charsets.UTF_8))
            }

            if (connection.responseCode !in 200..299) {
                return null
            }

            val body = connection.inputStream.bufferedReader().use { it.readText() }
            val json = JSONObject(body)
            val choices = json.optJSONArray("choices") ?: return null
            if (choices.length() == 0) return null
            val message = choices.getJSONObject(0).optJSONObject("message") ?: return null
            message.optString("content", "").ifBlank { null }
        } catch (e: Exception) {
            null
        } finally {
            connection?.disconnect()
        }
    }

    private suspend fun handleCommand(parsed: JSONObject, backend: DiscoveredBackend): BrainResponse {
        val actionName = parsed.optString("action", "").uppercase()
        val argsJson = parsed.optJSONObject("args") ?: JSONObject()
        val action = buildAction(actionName, argsJson)

        if (action == null) {
            val content = parsed.optString("content", "I understood you wanted to run a command, but I don't know which one.")
            insert(ChatMessage(role = "assistant", content = content))
            return BrainResponse(text = content)
        }

        if (requiresConfirmation(action)) {
            pendingAction = action
            val content = parsed.optString("content", "I'll run ${action.name}. Approve?")
            insert(
                ChatMessage(
                    role = "assistant",
                    content = content,
                    actionExecuted = action.name,
                    requiresConfirmation = true
                )
            )
            return BrainResponse(text = content, action = action, requiresConfirmation = true)
        }

        val result = commandEngine.performAction(action)
        insert(ChatMessage(role = "system", content = "Command result: ${result.message}"))
        val summary = summarizeResult(backend, result)
        insert(ChatMessage(role = "assistant", content = summary))
        return BrainResponse(text = summary, action = action, actionResult = result)
    }

    private fun summarizeResult(backend: DiscoveredBackend, result: CommandResult): String {
        return result.message
    }

    private fun requiresConfirmation(action: CommandAction): Boolean {
        return when (action) {
            is CommandAction.GetTimeDate,
            is CommandAction.GetBatteryStatus,
            is CommandAction.GetNextAlarm,
            is CommandAction.GetJoke,
            is CommandAction.GetWeather,
            is CommandAction.GetTodaySchedule,
            is CommandAction.Calculate,
            is CommandAction.RollDice,
            is CommandAction.FlipCoin -> false
            else -> true
        }
    }

    private fun systemPrompt(): String {
        return loadPromptFromAssets() ?: DEFAULT_SYSTEM_PROMPT
    }

    private fun loadPromptFromAssets(): String? {
        return try {
            context.assets.open("nexus_brain_system_prompt.md").use { stream ->
                stream.bufferedReader().use { it.readText() }
            }
        } catch (e: Exception) {
            null
        }
    }

    companion object {
        const val MAX_CONTEXT_CHARS = 3000

        // Inline fallback so the prompt works even if the shared asset is missing.
        // Keep it in sync with shared/prompts/nexus_brain_system_prompt.md.
        // Tests verify it matches the shared file.
        const val DEFAULT_SYSTEM_PROMPT = """You are Nexus, a helpful local voice assistant. The user talks to you naturally.
You can either reply conversationally OR run one of the supported commands.
Always respond with a single JSON object exactly in this format:
{"type": "chat", "content": "Your natural reply here."}
or
{"type": "command", "content": "What you are about to do", "action": "ACTION_NAME", "args": {...}}

When type is 'command', action must be one of these names and args must match:
OPEN_APP: {package_name: string}
OPEN_WEBSITE: {url: string}
WEB_SEARCH: {query: string}
TOGGLE_WIFI, TOGGLE_BLUETOOTH, TOGGLE_FLASHLIGHT, TOGGLE_DND: {enable: bool}
SET_BRIGHTNESS: {level: int}
SET_VOLUME: {percent: int}, ADJUST_VOLUME: {delta: int}, MUTE_VOLUME: {}
PLAY_MEDIA: {query: string}, PLAY_MEDIA_APP: {query: string, app_name: string}
PAUSE_MEDIA: {query?: string}, MEDIA_CONTROL: {command: string}
SET_TIMER: {seconds: int, label?: string}
SET_ALARM: {hour: int, minute: int, label?: string, repeating?: bool}
TAKE_NOTE: {content: string}
ROLL_DICE: {sides?: int}, FLIP_COIN: {}
NAVIGATE: {destination: string}
OPEN_CALENDAR: {}, CALCULATE: {expression: string}
SMART_HOME: {device: string, operation: string, value?: string|null}
LIST_ACTION: {item: string, list_name: string}
SET_REMINDER: {task: string}
SEARCH_INFO: {query: string, search_type: string}
OPEN_CAMERA: {is_selfie: bool}, RECORD_VIDEO: {}
CALL_CONTACT: {contact: string}, SEND_TEXT: {contact: string, message?: string}
SEND_EMAIL: {recipient: string}
CANCEL_ALARM_TIMER: {}
GET_TIME_DATE, GET_BATTERY_STATUS, GET_NEXT_ALARM, GET_JOKE, GET_WEATHER, GET_TODAY_SCHEDULE
If the request does not match any command, use type 'chat'.
"""

        @JvmStatic
        fun parseResponse(content: String): JSONObject? {
            return try {
                val cleaned = content
                    .replace(Regex("^```(?:json)?\\s*", RegexOption.IGNORE_CASE), "")
                    .replace(Regex("\\s*```$", RegexOption.IGNORE_CASE), "")
                JSONObject(cleaned)
            } catch (e: Exception) {
                null
            }
        }

        @JvmStatic
        fun buildAction(name: String, args: JSONObject): CommandAction? {
            return try {
                when (name) {
                    "OPEN_APP" -> CommandAction.OpenApp(args.optString("package_name", ""))
                    "OPEN_WEBSITE" -> CommandAction.OpenWebsite(args.optString("url", ""))
                    "WEB_SEARCH" -> CommandAction.WebSearch(args.optString("query", ""))
                    "TOGGLE_WIFI" -> CommandAction.ToggleWifi(args.optBoolean("enable", true))
                    "TOGGLE_BLUETOOTH" -> CommandAction.ToggleBluetooth(args.optBoolean("enable", true))
                    "SET_BRIGHTNESS" -> CommandAction.SetBrightness(args.optInt("level", 50))
                    "SET_VOLUME" -> CommandAction.SetVolume(args.optInt("percent", 50))
                    "ADJUST_VOLUME" -> CommandAction.AdjustVolume(args.optInt("delta", 0))
                    "MUTE_VOLUME" -> CommandAction.MuteVolume()
                    "PLAY_MEDIA" -> CommandAction.PlayMedia(args.optString("query", ""))
                    "PLAY_MEDIA_APP" -> CommandAction.PlayMediaApp(
                        args.optString("query", ""),
                        args.optString("app_name", "")
                    )
                    "PAUSE_MEDIA" -> CommandAction.PauseMedia(args.optString("query", ""))
                    "MEDIA_CONTROL" -> CommandAction.MediaControl(args.optString("command", ""))
                    "TOGGLE_FLASHLIGHT" -> CommandAction.ToggleFlashlight(args.optBoolean("enable", true))
                    "SET_TIMER" -> CommandAction.SetTimer(
                        args.optInt("seconds", 60),
                        args.optString("label", "").ifBlank { null }
                    )
                    "SET_ALARM" -> CommandAction.SetAlarm(
                        args.optInt("hour", 7),
                        args.optInt("minute", 0),
                        args.optString("label", "").ifBlank { null },
                        args.optBoolean("repeating", false)
                    )
                    "TAKE_NOTE" -> CommandAction.TakeNote(args.optString("content", ""))
                    "ROLL_DICE" -> CommandAction.RollDice(args.optInt("sides", 6))
                    "FLIP_COIN" -> CommandAction.FlipCoin()
                    "TOGGLE_DND" -> CommandAction.ToggleDnd(args.optBoolean("enable", true))
                    "NAVIGATE" -> CommandAction.Navigate(args.optString("destination", ""))
                    "OPEN_CALENDAR" -> CommandAction.OpenCalendar()
                    "CALCULATE" -> CommandAction.Calculate(args.optString("expression", ""))
                    "SMART_HOME" -> CommandAction.SmartHome(
                        args.optString("device", ""),
                        args.optString("operation", "SET_STATE"),
                        args.optString("value", "").ifBlank { null }
                    )
                    "LIST_ACTION" -> CommandAction.ListAction(
                        args.optString("item", ""),
                        args.optString("list_name", "todo")
                    )
                    "SET_REMINDER" -> CommandAction.SetReminder(args.optString("task", ""))
                    "SEARCH_INFO" -> CommandAction.SearchInfo(
                        args.optString("query", ""),
                        args.optString("search_type", "Define")
                    )
                    "OPEN_CAMERA" -> CommandAction.OpenCamera(args.optBoolean("is_selfie", false))
                    "RECORD_VIDEO" -> CommandAction.RecordVideo()
                    "CALL_CONTACT" -> CommandAction.CallContact(args.optString("contact", ""))
                    "SEND_TEXT" -> CommandAction.SendText(
                        args.optString("contact", ""),
                        args.optString("message", "").ifBlank { null }
                    )
                    "SEND_EMAIL" -> CommandAction.SendEmail(args.optString("recipient", ""))
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
                null
            }
        }
    }
}
