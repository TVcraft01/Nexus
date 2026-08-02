package com.nexus.app.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import com.nexus.app.data.local.entity.RoutineSuggestionEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface RoutineSuggestionDao {

    @Query("SELECT * FROM routine_suggestions WHERE dismissed = 0 ORDER BY confidence DESC LIMIT :limit")
    fun getActiveSuggestions(limit: Int = 10): Flow<List<RoutineSuggestionEntity>>

    @Query("SELECT * FROM routine_suggestions WHERE dismissed = 0 ORDER BY confidence DESC LIMIT :limit")
    suspend fun getActiveSuggestionsSync(limit: Int = 10): List<RoutineSuggestionEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: RoutineSuggestionEntity)

    @Query("UPDATE routine_suggestions SET dismissed = 1 WHERE id = :id")
    suspend fun dismiss(id: String)

    @Query("DELETE FROM routine_suggestions WHERE action_type = :actionType AND payload = :payload")
    suspend fun deleteByAction(actionType: String, payload: String)

    @Query("DELETE FROM routine_suggestions")
    suspend fun clearAll()
}
