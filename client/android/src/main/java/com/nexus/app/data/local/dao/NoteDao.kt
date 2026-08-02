package com.nexus.app.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import com.nexus.app.data.local.entity.NoteEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface NoteDao {

    @Insert
    suspend fun insert(note: NoteEntity): Long

    @Query("SELECT * FROM notes ORDER BY timestamp DESC LIMIT :limit")
    fun getRecentNotes(limit: Int = 100): Flow<List<NoteEntity>>

    @Query("DELETE FROM notes WHERE id = :noteId")
    suspend fun deleteById(noteId: Long)

    @Query("DELETE FROM notes")
    suspend fun clearAll()
}
