package com.nexus.app.mesh

/**
 * Parsed payload from a Nexus device pairing QR code.
 */
data class QrPairingData(
    val nodeId: String,
    val nodeName: String,
    val pin: String
)
