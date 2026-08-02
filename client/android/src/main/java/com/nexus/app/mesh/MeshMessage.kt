package com.nexus.app.mesh

import android.util.Base64
import org.json.JSONObject
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Encrypted envelope used for all mesh command/context relay between Nexus nodes.
 */
data class MeshMessage(
    val senderId: String,
    val type: MeshMessageType,
    val iv: ByteArray,
    val payload: ByteArray,
    val timestamp: Long = System.currentTimeMillis()
) {
    fun toJson(): String {
        return JSONObject().apply {
            put("senderId", senderId)
            put("type", type.name)
            put("iv", Base64.encodeToString(iv, Base64.NO_WRAP))
            put("payload", Base64.encodeToString(payload, Base64.NO_WRAP))
            put("timestamp", timestamp)
        }.toString()
    }

    companion object {
        fun fromJson(jsonString: String): MeshMessage {
            val json = JSONObject(jsonString)
            return MeshMessage(
                senderId = json.getString("senderId"),
                type = MeshMessageType.valueOf(json.getString("type")),
                iv = Base64.decode(json.getString("iv"), Base64.NO_WRAP),
                payload = Base64.decode(json.getString("payload"), Base64.NO_WRAP),
                timestamp = json.optLong("timestamp", System.currentTimeMillis())
            )
        }
    }
}

enum class MeshMessageType {
    COMMAND,        // Execute a command and return result
    QUERY,          // Ask a question / offload a query
    CONTEXT,        // Pass conversation/memory context
    PAIRING_REQUEST,
    PAIRING_RESPONSE,
    RESULT          // Response to a command/query
}

/**
 * Plain-text payload carried inside a [MeshMessage] after decryption.
 */
data class MeshPayload(
    val command: String? = null,
    val context: String? = null,
    val result: String? = null,
    val success: Boolean = true
) {
    fun toJson(): String {
        return JSONObject().apply {
            putOpt("command", command)
            putOpt("context", context)
            putOpt("result", result)
            put("success", success)
        }.toString()
    }

    companion object {
        fun fromJson(jsonString: String): MeshPayload {
            val json = JSONObject(jsonString)
            return MeshPayload(
                command = json.optString("command").takeIf { it.isNotEmpty() },
                context = json.optString("context").takeIf { it.isNotEmpty() },
                result = json.optString("result").takeIf { it.isNotEmpty() },
                success = json.optBoolean("success", true)
            )
        }
    }
}
