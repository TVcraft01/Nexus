package com.nexus.app.brain

data class ChatMessage(
    val id: String = java.util.UUID.randomUUID().toString(),
    val timestamp: Long = System.currentTimeMillis(),
    val role: String,
    val content: String,
    val actionExecuted: String? = null,
    val requiresConfirmation: Boolean = false
)
