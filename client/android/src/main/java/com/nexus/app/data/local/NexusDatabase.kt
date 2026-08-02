package com.nexus.app.data.local

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import com.nexus.app.data.local.dao.ChatMessageDao
import com.nexus.app.data.local.dao.CommandHistoryDao
import com.nexus.app.data.local.dao.MemoryLogDao
import com.nexus.app.data.local.dao.NoteDao
import com.nexus.app.data.local.dao.RoutineSuggestionDao
import com.nexus.app.data.local.dao.SettingDao
import com.nexus.app.data.local.dao.UserRuleDao
import com.nexus.app.data.local.entity.ChatMessageEntity
import com.nexus.app.data.local.entity.CommandHistoryEntity
import com.nexus.app.data.local.entity.MemoryLogEntity
import com.nexus.app.data.local.entity.NoteEntity
import com.nexus.app.data.local.entity.RoutineSuggestionEntity
import com.nexus.app.data.local.entity.SettingEntity
import com.nexus.app.data.local.entity.UserRuleEntity
import net.sqlcipher.database.SupportFactory

@Database(
    entities = [
        MemoryLogEntity::class,
        UserRuleEntity::class,
        SettingEntity::class,
        NoteEntity::class,
        CommandHistoryEntity::class,
        RoutineSuggestionEntity::class,
        ChatMessageEntity::class
    ],
    version = 4,
    exportSchema = false
)
abstract class NexusDatabase : RoomDatabase() {

    abstract fun memoryLogDao(): MemoryLogDao
    abstract fun userRuleDao(): UserRuleDao
    abstract fun settingDao(): SettingDao
    abstract fun noteDao(): NoteDao
    abstract fun commandHistoryDao(): CommandHistoryDao
    abstract fun routineSuggestionDao(): RoutineSuggestionDao
    abstract fun chatMessageDao(): ChatMessageDao

    companion object {
        @Volatile
        private var INSTANCE: NexusDatabase? = null

        fun getInstance(context: Context, passphraseProvider: () -> ByteArray): NexusDatabase {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: buildDatabase(context, passphraseProvider).also { INSTANCE = it }
            }
        }

        private val MIGRATION_2_3 = object : androidx.room.migration.Migration(2, 3) {
            override fun migrate(database: androidx.sqlite.db.SupportSQLiteDatabase) {
                database.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS command_history (
                        id TEXT NOT NULL PRIMARY KEY,
                        input TEXT NOT NULL,
                        action_type TEXT NOT NULL,
                        payload TEXT NOT NULL,
                        timestamp INTEGER NOT NULL,
                        hour_of_day INTEGER NOT NULL,
                        day_index INTEGER NOT NULL
                    )
                    """.trimIndent()
                )
                database.execSQL("CREATE INDEX IF NOT EXISTS index_command_history_action_payload_hour ON command_history(action_type, payload, hour_of_day)")
                database.execSQL("CREATE INDEX IF NOT EXISTS index_command_history_timestamp ON command_history(timestamp)")
                database.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS routine_suggestions (
                        id TEXT NOT NULL PRIMARY KEY,
                        input TEXT NOT NULL,
                        action_type TEXT NOT NULL,
                        payload TEXT NOT NULL,
                        hour_of_day INTEGER NOT NULL,
                        confidence INTEGER NOT NULL,
                        last_suggested_at INTEGER,
                        dismissed INTEGER NOT NULL
                    )
                    """.trimIndent()
                )
                database.execSQL("CREATE UNIQUE INDEX IF NOT EXISTS index_routine_suggestions_action_payload ON routine_suggestions(action_type, payload)")
            }
        }

        private fun buildDatabase(context: Context, passphraseProvider: () -> ByteArray): NexusDatabase {
            net.sqlcipher.database.SQLiteDatabase.loadLibs(context.applicationContext)
            val passphrase = passphraseProvider()
            val factory = SupportFactory(passphrase)
            return Room.databaseBuilder(
                context.applicationContext,
                NexusDatabase::class.java,
                "nexus_identity_vault.db"
            )
                .openHelperFactory(factory)
                .addMigrations(MIGRATION_2_3, MIGRATION_3_4)
                .fallbackToDestructiveMigration()
                .build()
        }

        private val MIGRATION_3_4 = object : androidx.room.migration.Migration(3, 4) {
            override fun migrate(database: androidx.sqlite.db.SupportSQLiteDatabase) {
                database.execSQL(
                    """
                    CREATE TABLE IF NOT EXISTS chat_messages (
                        id TEXT NOT NULL PRIMARY KEY,
                        timestamp INTEGER NOT NULL,
                        role TEXT NOT NULL,
                        content TEXT NOT NULL,
                        action_executed TEXT,
                        requires_confirmation INTEGER NOT NULL DEFAULT 0
                    )
                    """.trimIndent()
                )
                database.execSQL("CREATE INDEX IF NOT EXISTS index_chat_messages_timestamp ON chat_messages(timestamp)")
            }
        }
    }
}
