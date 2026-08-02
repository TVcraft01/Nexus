package com.nexus.app.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import com.nexus.app.data.local.entity.ChatMessageEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface ChatMessageDao {

    @Query("SELECT * FROM chat_messages ORDER BY timestamp ASC LIMIT :limit")
    fun getRecentMessages(limit: Int = 200): Flow<List<ChatMessageEntity>>

    @Query("SELECT * FROM chat_messages ORDER BY timestamp ASC LIMIT :limit")
    suspend fun getRecentMessagesSync(limit: Int = 200): List<ChatMessageEntity>

    @Insert
    suspend fun insert(message: ChatMessageEntity)

    @Query("DELETE FROM chat_messages")
    suspend fun clearAll()
}
