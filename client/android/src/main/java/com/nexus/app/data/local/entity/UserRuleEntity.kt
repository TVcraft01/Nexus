package com.nexus.app.data.local.entity

import androidx.annotation.Keep
import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey

@Keep
@Entity(tableName = "user_rules")
data class UserRuleEntity(
    @PrimaryKey
    @ColumnInfo(name = "id")
    val id: String = java.util.UUID.randomUUID().toString(),

    @ColumnInfo(name = "pattern")
    val pattern: String,

    @ColumnInfo(name = "action_type")
    val actionType: String,

    @ColumnInfo(name = "payload")
    val payload: String = "",

    @ColumnInfo(name = "enabled")
    val enabled: Boolean = true,

    @ColumnInfo(name = "priority")
    val priority: Int = 100
)
