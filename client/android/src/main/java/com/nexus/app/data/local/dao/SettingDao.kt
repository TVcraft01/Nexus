package com.nexus.app.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.nexus.app.data.local.entity.SettingEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface SettingDao {

    @Query("SELECT * FROM settings WHERE key = :key LIMIT 1")
    suspend fun get(key: String): SettingEntity?

    @Query("SELECT * FROM settings WHERE key = :key LIMIT 1")
    fun getFlow(key: String): Flow<SettingEntity?>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun set(setting: SettingEntity)
}
