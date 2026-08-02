package com.nexus.app.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.nexus.app.data.local.entity.UserRuleEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface UserRuleDao {

    @Query("SELECT * FROM user_rules WHERE enabled = 1 ORDER BY priority DESC")
    fun getEnabledRules(): Flow<List<UserRuleEntity>>

    @Query("SELECT * FROM user_rules WHERE enabled = 1 ORDER BY priority DESC")
    suspend fun getEnabledRulesSync(): List<UserRuleEntity>

    @Query("SELECT * FROM user_rules ORDER BY priority DESC")
    suspend fun getAllRules(): List<UserRuleEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertOrUpdate(rule: UserRuleEntity)

    @Query("DELETE FROM user_rules WHERE id = :ruleId")
    suspend fun deleteById(ruleId: String)

    @Query("DELETE FROM user_rules")
    suspend fun deleteAllUserRules()
}
