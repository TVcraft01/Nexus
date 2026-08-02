package com.nexus.app.data.security

import android.content.Context
import android.content.SharedPreferences
import android.util.Base64
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.security.SecureRandom

object VaultKeyManager {

    private const val PREFS_FILE = "nexus_vault_keys"
    private const val KEY_DB_PASSPHRASE = "db_passphrase"

    private fun preferences(context: Context): SharedPreferences {
        val masterKey = try {
            MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
        } catch (e: Exception) {
            Log.w("VaultKeyManager", "Keystore init failed, clearing encrypted prefs", e)
            clearPreferences(context)
            MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
        }

        return try {
            EncryptedSharedPreferences.create(
                context,
                PREFS_FILE,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        } catch (e: Exception) {
            Log.w("VaultKeyManager", "EncryptedSharedPreferences corrupted, clearing", e)
            clearPreferences(context)
            EncryptedSharedPreferences.create(
                context,
                PREFS_FILE,
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        }
    }

    private fun clearPreferences(context: Context) {
        context.deleteSharedPreferences(PREFS_FILE)
    }

    fun getOrCreatePassphrase(context: Context): ByteArray {
        val prefs = preferences(context)
        val stored = prefs.getString(KEY_DB_PASSPHRASE, null)
        return if (stored.isNullOrBlank()) {
            val bytes = generatePassphrase(32)
            prefs.edit().putString(KEY_DB_PASSPHRASE, Base64.encodeToString(bytes, Base64.NO_WRAP)).apply()
            bytes
        } else {
            Base64.decode(stored, Base64.NO_WRAP)
        }
    }

    private fun generatePassphrase(size: Int): ByteArray {
        val bytes = ByteArray(size)
        SecureRandom().nextBytes(bytes)
        return bytes
    }
}
