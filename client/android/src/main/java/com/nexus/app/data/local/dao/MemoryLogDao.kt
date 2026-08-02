package com.nexus.app.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import com.nexus.app.data.local.entity.MemoryLogEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface MemoryLogDao {

    @Query("SELECT * FROM memory_logs ORDER BY timestamp DESC LIMIT :limit")
    fun getRecentLogs(limit: Int = 200): Flow<List<MemoryLogEntity>>

    @Query("SELECT * FROM memory_logs ORDER BY timestamp DESC LIMIT :limit")
    suspend fun getRecentLogsSync(limit: Int = 200): List<MemoryLogEntity>

    @Insert
    suspend fun insert(log: MemoryLogEntity)

    suspend fun insert(message: String, level: String = "INFO") {
        insert(MemoryLogEntity(message = message, level = level))
    }

    @Query("DELETE FROM memory_logs")
    suspend fun clearAll()
}
