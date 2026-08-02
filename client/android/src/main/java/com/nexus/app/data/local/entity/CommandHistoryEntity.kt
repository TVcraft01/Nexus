package com.nexus.app.data.local.entity

import androidx.annotation.Keep
import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * Structured command history used for on-device routine detection.
 *
 * One row is inserted each time a command is successfully executed.
 * The [hourOfDay] and [dayOfWeek] fields are denormalized to make
 * time-bucketed routine queries cheap.
 */
@Keep
@Entity(
    tableName = "command_history",
    indices = [
        Index(value = ["action_type", "payload", "hour_of_day"]),
        Index(value = ["timestamp"])
    ]
)
data class CommandHistoryEntity(
    @PrimaryKey
    @ColumnInfo(name = "id")
    val id: String = java.util.UUID.randomUUID().toString(),

    @ColumnInfo(name = "input")
    val input: String,

    @ColumnInfo(name = "action_type")
    val actionType: String,

    @ColumnInfo(name = "payload")
    val payload: String = "",

    @ColumnInfo(name = "timestamp")
    val timestamp: Long = System.currentTimeMillis(),

    @ColumnInfo(name = "hour_of_day")
    val hourOfDay: Int,

    /**
     * Calendar day index (days since Unix epoch) used to count distinct days.
     */
    @ColumnInfo(name = "day_index")
    val dayIndex: Int
)
