package com.nexus.app.data.local.entity

import androidx.annotation.Keep
import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey

@Keep
@Entity(tableName = "chat_messages")
data class ChatMessageEntity(
    @PrimaryKey
    @ColumnInfo(name = "id")
    val id: String = java.util.UUID.randomUUID().toString(),

    @ColumnInfo(name = "timestamp")
    val timestamp: Long = System.currentTimeMillis(),

    @ColumnInfo(name = "role")
    val role: String,

    @ColumnInfo(name = "content")
    val content: String,

    @ColumnInfo(name = "action_executed")
    val actionExecuted: String? = null,

    @ColumnInfo(name = "requires_confirmation")
    val requiresConfirmation: Boolean = false
)
