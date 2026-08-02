package com.nexus.app.command

import android.content.Context
import android.util.Log
import androidx.annotation.Keep
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.nexus.app.data.local.NexusDatabase
import com.nexus.app.data.local.entity.UserRuleEntity
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.util.UUID

class UserRulesRepository(
    context: Context,
    private val database: NexusDatabase
) {
    private val appContext = context.applicationContext
    private val gson = Gson()
    private val jsonFile = File(appContext.filesDir, "user_dialect_rules.json")

    suspend fun getEnabledRules(): List<UserDialectRule> = withContext(Dispatchers.IO) {
        database.userRuleDao().getEnabledRulesSync().map { it.toUserDialectRule() }
    }

    fun getEnabledRulesFlow(): Flow<List<UserDialectRule>> {
        return database.userRuleDao().getEnabledRules()
            .map { list -> list.map { it.toUserDialectRule() } }
    }

    suspend fun getAllRules(): List<UserDialectRule> = withContext(Dispatchers.IO) {
        database.userRuleDao().getAllRules().map { it.toUserDialectRule() }
    }

    suspend fun addRule(rule: UserDialectRule): Boolean = withContext(Dispatchers.IO) {
        return@withContext try {
            database.userRuleDao().insertOrUpdate(rule.toEntity())
            exportToJson()
            true
        } catch (e: Exception) {
            Log.e("UserRulesRepository", "Failed to add rule", e)
            false
        }
    }

    suspend fun deleteRule(ruleId: String): Boolean = withContext(Dispatchers.IO) {
        return@withContext try {
            database.userRuleDao().deleteById(ruleId)
            exportToJson()
            true
        } catch (e: Exception) {
            Log.e("UserRulesRepository", "Failed to delete rule", e)
            false
        }
    }

    suspend fun importFromJson(json: String): Boolean = withContext(Dispatchers.IO) {
        return@withContext try {
            val type = object : TypeToken<List<UserDialectRule>>() {}.type
            val rules: List<UserDialectRule> = gson.fromJson(json, type)
            database.userRuleDao().deleteAllUserRules()
            rules.forEach { database.userRuleDao().insertOrUpdate(it.toEntity()) }
            exportToJson()
            true
        } catch (e: Exception) {
            Log.e("UserRulesRepository", "Failed to import rules", e)
            false
        }
    }

    suspend fun exportToJson(): String = withContext(Dispatchers.IO) {
        val rules = getAllRules()
        val json = gson.toJson(rules)
        try {
            jsonFile.writeText(json)
        } catch (e: IOException) {
            Log.e("UserRulesRepository", "Failed to write JSON backup", e)
        }
        return@withContext json
    }

    suspend fun loadBackupJson(): String? = withContext(Dispatchers.IO) {
        return@withContext if (jsonFile.exists()) {
            try {
                jsonFile.readText()
            } catch (e: IOException) {
                Log.e("UserRulesRepository", "Failed to read JSON backup", e)
                null
            }
        } else {
            null
        }
    }

    private fun UserDialectRule.toEntity(): UserRuleEntity {
        return UserRuleEntity(
            id = id,
            pattern = pattern,
            actionType = actionType,
            payload = payload,
            enabled = enabled,
            priority = priority
        )
    }

    private fun UserRuleEntity.toUserDialectRule(): UserDialectRule {
        return UserDialectRule(
            id = id,
            pattern = pattern,
            actionType = actionType,
            payload = payload,
            enabled = enabled,
            priority = priority
        )
    }
}
