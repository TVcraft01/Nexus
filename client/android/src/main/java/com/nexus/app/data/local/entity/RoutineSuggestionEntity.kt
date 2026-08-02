package com.nexus.app.data.local.entity

import androidx.annotation.Keep
import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * A detected routine that Nexus can proactively suggest to the user.
 *
 * Storing suggestions allows the user to dismiss them and lets us avoid
 * re-computing the same pattern every time the app opens.
 */
@Keep
@Entity(
    tableName = "routine_suggestions",
    indices = [
        Index(value = ["action_type", "payload"], unique = true)
    ]
)
data class RoutineSuggestionEntity(
    @PrimaryKey
    @ColumnInfo(name = "id")
    val id: String = java.util.UUID.randomUUID().toString(),

    @ColumnInfo(name = "input")
    val input: String,

    @ColumnInfo(name = "action_type")
    val actionType: String,

    @ColumnInfo(name = "payload")
    val payload: String = "",

    @ColumnInfo(name = "hour_of_day")
    val hourOfDay: Int,

    /**
     * Confidence is the number of distinct days on which this routine
     * has been observed at the same hour.
     */
    @ColumnInfo(name = "confidence")
    val confidence: Int,

    @ColumnInfo(name = "last_suggested_at")
    val lastSuggestedAt: Long? = null,

    @ColumnInfo(name = "dismissed")
    val dismissed: Boolean = false
)
