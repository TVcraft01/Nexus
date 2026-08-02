package com.nexus.app.command

import androidx.annotation.Keep
import com.google.gson.annotations.SerializedName

@Keep
data class UserDialectRule(
    @SerializedName("id")
    val id: String,
    @SerializedName("pattern")
    val pattern: String,
    @SerializedName("actionType")
    val actionType: String,
    @SerializedName("payload")
    val payload: String = "",
    @SerializedName("enabled")
    val enabled: Boolean = true,
    @SerializedName("priority")
    val priority: Int = 100
) {
    companion object {
        fun createNew(
            pattern: String,
            actionType: String,
            payload: String = "",
            priority: Int = 100
        ): UserDialectRule {
            return UserDialectRule(
                id = java.util.UUID.randomUUID().toString(),
                pattern = pattern,
                actionType = actionType,
                payload = payload,
                enabled = true,
                priority = priority
            )
        }
    }
}
