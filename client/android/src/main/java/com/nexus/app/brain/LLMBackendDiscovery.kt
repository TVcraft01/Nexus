package com.nexus.app.brain

import android.app.ActivityManager
import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

 data class LLMBackend(
    val name: String,
    val baseUrl: String,
    val chatEndpoint: String,
    val modelsEndpoint: String,
    val healthEndpoint: String? = null
)

 data class DiscoveredBackend(
    val backend: LLMBackend,
    val models: List<String> = emptyList(),
    val selectedModel: String? = null
)

 data class ModelRecommendation(
    val maxBillions: Int,
    val reasoning: String,
    val examples: List<String>
)

 object LLMBackendDiscovery {

    private val KNOWN_BACKENDS = listOf(
        LLMBackend(
            name = "Ollama",
            baseUrl = "http://127.0.0.1:11434",
            chatEndpoint = "http://127.0.0.1:11434/v1/chat/completions",
            modelsEndpoint = "http://127.0.0.1:11434/api/tags",
            healthEndpoint = "http://127.0.0.1:11434/api/tags"
        ),
        LLMBackend(
            name = "LM Studio",
            baseUrl = "http://127.0.0.1:1234",
            chatEndpoint = "http://127.0.0.1:1234/v1/chat/completions",
            modelsEndpoint = "http://127.0.0.1:1234/v1/models"
        ),
        LLMBackend(
            name = "llama.cpp",
            baseUrl = "http://127.0.0.1:8080",
            chatEndpoint = "http://127.0.0.1:8080/v1/chat/completions",
            modelsEndpoint = "http://127.0.0.1:8080/v1/models"
        )
    )

    fun recommendModel(totalRamMb: Long): ModelRecommendation {
        val ramGb = totalRamMb / 1024.0
        return when {
            ramGb < 4 -> ModelRecommendation(
                maxBillions = 2,
                reasoning = "Only %.1f GB RAM available. A 1-2B model is the safe choice.".format(ramGb),
                examples = listOf("Llama-3.2-1B-Instruct", "Qwen2.5-1.5B-Instruct")
            )
            ramGb < 8 -> ModelRecommendation(
                maxBillions = 4,
                reasoning = "%.1f GB RAM available. A 3-4B model fits well.".format(ramGb),
                examples = listOf("Llama-3.2-3B-Instruct", "Phi-3.5-mini")
            )
            ramGb < 16 -> ModelRecommendation(
                maxBillions = 8,
                reasoning = "%.1f GB RAM available. A 7-8B model is comfortable.".format(ramGb),
                examples = listOf("Llama-3.1-8B-Instruct", "Qwen2.5-7B-Instruct")
            )
            else -> ModelRecommendation(
                maxBillions = 14,
                reasoning = "%.1f GB RAM available. You can run a 13-14B model or larger.".format(ramGb),
                examples = listOf("Llama-3.1-8B-Instruct", "Qwen2.5-14B-Instruct")
            )
        }
    }

    fun getTotalRamMb(context: Context): Long {
        val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
        val info = ActivityManager.MemoryInfo()
        activityManager?.getMemoryInfo(info)
        return info.totalMem / (1024 * 1024)
    }

    suspend fun discoverBackends(context: Context): List<DiscoveredBackend> = withContext(Dispatchers.IO) {
        val discovered = mutableListOf<DiscoveredBackend>()
        for (backend in KNOWN_BACKENDS) {
            try {
                val models = fetchModels(backend.modelsEndpoint)
                if (models != null) {
                    val selected = selectModel(context, backend, models)
                    discovered.add(DiscoveredBackend(backend, models, selected))
                }
            } catch (e: Exception) {
                // Ignore unreachable backends
            }
        }
        discovered
    }

    suspend fun bestBackend(context: Context): DiscoveredBackend? {
        val backends = discoverBackends(context)
        return backends.firstOrNull { it.models.isNotEmpty() }
    }

    private fun selectModel(context: Context, backend: LLMBackend, models: List<String>): String? {
        val recommendation = recommendModel(getTotalRamMb(context))
        val regex = Regex("(\\d+)(?:\\.[0-9])?[bB]")
        for (model in models) {
            val match = regex.find(model)
            val billions = match?.groupValues?.get(1)?.toIntOrNull() ?: Int.MAX_VALUE
            if (billions <= recommendation.maxBillions) {
                return model
            }
        }
        return models.firstOrNull()
    }

    private fun fetchModels(urlString: String): List<String>? {
        var connection: HttpURLConnection? = null
        return try {
            val url = URL(urlString)
            connection = url.openConnection() as HttpURLConnection
            connection.requestMethod = "GET"
            connection.connectTimeout = 500
            connection.readTimeout = 1000
            connection.setRequestProperty("Accept", "application/json")
            if (connection.responseCode !in 200..299) {
                return null
            }
            val body = connection.inputStream.bufferedReader().use { it.readText() }
            val json = JSONObject(body)
            parseModels(json)
        } catch (e: Exception) {
            null
        } finally {
            connection?.disconnect()
        }
    }

    private fun parseModels(json: JSONObject): List<String> {
        val models = mutableListOf<String>()
        if (json.has("models")) {
            val array = json.getJSONArray("models")
            for (i in 0 until array.length()) {
                val item = array.getJSONObject(i)
                val name = item.optString("name") ?: item.optString("model") ?: item.optString("id")
                if (name.isNotBlank()) {
                    models.add(name)
                }
            }
        } else if (json.has("data")) {
            val array = json.getJSONArray("data")
            for (i in 0 until array.length()) {
                val item = array.getJSONObject(i)
                val name = item.optString("id") ?: item.optString("name")
                if (name.isNotBlank()) {
                    models.add(name)
                }
            }
        }
        return models
    }
}
