package com.nexus.app.mesh

import org.json.JSONObject

/**
 * Parses Nexus pairing QR code contents into [QrPairingData].
 *
 * The expected JSON format is:
 * ```json
 * {"nodeId": "...", "nodeName": "...", "pin": "..."}
 * ```
 */
object QrPairingParser {

    /**
     * Parses [contents] into a [QrPairingData] object.
     *
     * @return a [QrPairingData] if the payload is valid, or `null` if the
     * content is not valid JSON or required fields are missing/blank.
     */
    fun parse(contents: String): QrPairingData? {
        return try {
            val json = JSONObject(contents)
            val nodeId = json.optString("nodeId").trim()
            val nodeName = json.optString("nodeName").trim()
            val pin = json.optString("pin").trim()
            if (nodeId.isBlank() || pin.isBlank()) {
                null
            } else {
                QrPairingData(nodeId, nodeName.ifBlank { nodeId }, pin)
            }
        } catch (_: Exception) {
            null
        }
    }
}
