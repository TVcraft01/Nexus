package com.nexus.app.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import com.nexus.app.data.local.entity.CommandHistoryEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface CommandHistoryDao {

    @Insert
    suspend fun insert(entry: CommandHistoryEntity)

    @Query(
        """
        SELECT action_type AS actionType, payload, hour_of_day AS hourOfDay, COUNT(DISTINCT day_index) AS days
        FROM command_history
        WHERE timestamp > :since
        GROUP BY action_type, payload, hour_of_day
        HAVING COUNT(DISTINCT day_index) >= :minDays
        ORDER BY days DESC
        LIMIT :limit
        """
    )
    suspend fun findRoutines(
        since: Long,
        minDays: Int = 3,
        limit: Int = 20
    ): List<RoutineRow>

    @Query("DELETE FROM command_history WHERE timestamp < :before")
    suspend fun pruneOld(before: Long)

    data class RoutineRow(
        val actionType: String,
        val payload: String,
        val hourOfDay: Int,
        val days: Int
    )
}
