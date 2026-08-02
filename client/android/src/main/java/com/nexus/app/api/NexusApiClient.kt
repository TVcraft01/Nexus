package com.nexus.app.api

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.Base64
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

/**
 * HTTP client for the Nexus orchestrator server API.
 *
 * Mirrors the Python client/desktop/api_client.py pattern.
 * Uses HttpURLConnection (consistent with existing Android codebase) and Gson for JSON.
 */
class NexusApiClient(
    val baseUrl: String = "http://10.0.2.2:9090", // 10.0.2.2 = host localhost from emulator
    private val timeout: Int = 10_000 // ms
) {
    private val gson = Gson()
    @Volatile var isConnected: Boolean = false
        private set

    // ── Low-level HTTP ──────────────────────────────────────────

    private fun url(path: String): URL = URL("$baseUrl$path")

    private suspend fun request(
        method: String, path: String, body: Any? = null
    ): String = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            connection = url(path).openConnection() as HttpURLConnection
            connection.connectTimeout = timeout
            connection.readTimeout = timeout
            connection.requestMethod = method
            connection.setRequestProperty("Accept", "application/json")
            connection.setRequestProperty("User-Agent", "Nexus-Android/0.3.0")

            if (body != null) {
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                OutputStreamWriter(connection.outputStream).use {
                    it.write(gson.toJson(body))
                    it.flush()
                }
            }

            val code = connection.responseCode
            val stream = if (code in 200..299) connection.inputStream else connection.errorStream
            val text = stream?.let { BufferedReader(InputStreamReader(it)).readText() } ?: "{}"
            isConnected = true
            text
        } catch (e: Exception) {
            isConnected = false
            """{"error":"${e.message?.replace("\"", "'")}"}"""
        } finally {
            connection?.disconnect()
        }
    }

    private suspend fun get(path: String): String = request("GET", path)
    private suspend fun post(path: String, body: Any? = null): String = request("POST", path, body)

    private suspend fun getRawBytes(path: String): ByteArray? = withContext(Dispatchers.IO) {
        var connection: HttpURLConnection? = null
        try {
            connection = url(path).openConnection() as HttpURLConnection
            connection.connectTimeout = 5000
            connection.readTimeout = 5000
            connection.requestMethod = "GET"
            connection.setRequestProperty("User-Agent", "Nexus-Android/0.3.0")
            val code = connection.responseCode
            if (code in 200..299) {
                isConnected = true
                connection.inputStream.readBytes()
            } else null
        } catch (e: Exception) {
            isConnected = false
            null
        } finally {
            connection?.disconnect()
        }
    }

    // ── JSON helpers ────────────────────────────────────────────

    private inline fun <reified T> parseJson(json: String): T? {
        return try {
            gson.fromJson(json, object : TypeToken<T>() {}.type)
        } catch (e: Exception) { null }
    }

    private fun parseJsonObject(json: String): Map<String, Any?>? =
        parseJson<Map<String, Any?>>(json)

    private fun parseJsonArray(json: String): List<Map<String, Any?>>? =
        parseJson<List<Map<String, Any?>>>(json)

    // ── Health ──────────────────────────────────────────────────

    suspend fun health(): Map<String, Any?>? = parseJsonObject(get("/health"))
    suspend fun serverStatus(): Map<String, Any?>? = parseJsonObject(get("/api/status"))

    // ── Vision ──────────────────────────────────────────────────

    suspend fun visionStatus(): Map<String, Any?>? =
        parseJsonObject(get("/api/vision/status"))

    suspend fun listCameras(): List<Map<String, Any?>>? =
        parseJsonArray(get("/api/vision/cameras"))

    suspend fun snapshotBase64(cameraId: String = "local-0"): Map<String, Any?>? =
        parseJsonObject(post("/api/vision/snapshot", mapOf("camera_id" to cameraId)))

    suspend fun snapshotJpeg(cameraId: String = "local-0"): ByteArray? =
        getRawBytes("/api/vision/snapshot/image?camera=$cameraId")

    suspend fun searchCameras(query: String): List<Map<String, Any?>>? =
        parseJsonArray(post("/api/vision/search", mapOf("query" to query)))

    suspend fun locateItem(item: String): Map<String, Any?>? =
        parseJsonObject(post("/api/vision/locate", mapOf("item" to item)))

    suspend fun warmupVision(): Map<String, Any?>? =
        parseJsonObject(get("/api/vision/warmup"))

    /**
     * Fetch a camera snapshot as a decoded Bitmap, plus optional detections.
     * Uses the base64 endpoint (one HTTP call) which returns both image and detections.
     */
    suspend fun snapshotBitmap(cameraId: String = "local-0"): SnapshotResult =
        withContext(Dispatchers.IO) {
            val snap = snapshotBase64(cameraId) ?: return@withContext SnapshotResult()
            val b64 = snap["image_base64"] as? String
            val bitmap = if (b64 != null) {
                try {
                    val bytes = Base64.decode(b64, Base64.DEFAULT)
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                } catch (e: Exception) { null }
            } else null

            @Suppress("UNCHECKED_CAST")
            val detections = snap["objects_detected"] as? List<Map<String, Any?>>
            SnapshotResult(bitmap = bitmap, detections = detections, filepath = snap["filepath"] as? String)
        }

    data class SnapshotResult(
        val bitmap: Bitmap? = null,
        val detections: List<Map<String, Any?>>? = null,
        val filepath: String? = null
    )

    // ── MQTT ────────────────────────────────────────────────────

    suspend fun mqttStatus(): Map<String, Any?>? =
        parseJsonObject(get("/api/mqtt/enable"))

    suspend fun enableMqtt(broker: String = "localhost", port: Int = 1883): Map<String, Any?>? =
        parseJsonObject(post("/api/mqtt/enable", mapOf("broker" to broker, "port" to port)))

    // ── Network / Tasks ─────────────────────────────────────────

    suspend fun networkSummary(): Map<String, Any?>? =
        parseJsonObject(get("/api/network"))

    suspend fun deviceCapabilities(): Map<String, Any?>? =
        parseJsonObject(get("/api/devices/capabilities"))

    suspend fun submitTask(
        description: String, workloadType: String = "command", priority: Int = 5
    ): Map<String, Any?>? = parseJsonObject(post("/api/tasks/submit", mapOf(
        "description" to description, "workload_type" to workloadType, "priority" to priority
    )))

    suspend fun listTasks(): List<Map<String, Any?>>? =
        parseJsonArray(get("/api/tasks"))

    // ── Routine Learning ────────────────────────────────────────

    suspend fun routines(): List<Map<String, Any?>>? =
        parseJsonArray(get("/api/routines"))

    suspend fun suggestions(): List<Map<String, Any?>>? =
        parseJsonArray(get("/api/suggestions"))

    suspend fun insights(): List<Map<String, Any?>>? =
        parseJsonArray(get("/api/insights"))

    suspend fun streaks(): List<Map<String, Any?>>? =
        parseJsonArray(get("/api/streaks"))

    suspend fun predictNext(): Map<String, Any?>? =
        parseJsonObject(get("/api/routines/predict"))
}
