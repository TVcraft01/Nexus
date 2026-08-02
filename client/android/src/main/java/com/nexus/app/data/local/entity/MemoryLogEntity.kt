package com.nexus.app.data.local.entity

import androidx.annotation.Keep
import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey

@Keep
@Entity(tableName = "memory_logs")
data class MemoryLogEntity(
    @PrimaryKey
    @ColumnInfo(name = "id")
    val id: String = java.util.UUID.randomUUID().toString(),

    @ColumnInfo(name = "timestamp")
    val timestamp: Long = System.currentTimeMillis(),

    @ColumnInfo(name = "message")
    val message: String,

    @ColumnInfo(name = "level")
    val level: String = "INFO"
)
