package com.nexus.app.mesh

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import javax.crypto.SecretKey

/**
 * Stores trusted peer identities and the shared AES-GCM keys used to encrypt
 * mesh traffic between Nexus nodes.
 */
class PeerTrustStore(context: Context) {

    private val prefs: SharedPreferences

    init {
        val masterKey = MasterKey.Builder(context, "nexus_mesh_master_key")
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        prefs = EncryptedSharedPreferences.create(
            context,
            "nexus_peer_trust_store",
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    fun storePeerKey(peerId: String, key: SecretKey) {
        prefs.edit()
            .putString("key_$peerId", MeshCrypto.encodeKeyBase64(key))
            .putBoolean("paired_$peerId", true)
            .apply()
        Log.d("PeerTrustStore", "Stored shared key for $peerId")
    }

    fun getPeerKey(peerId: String): SecretKey? {
        val encoded = prefs.getString("key_$peerId", null) ?: return null
        return MeshCrypto.decodeKeyBase64(encoded)
    }

    fun isPaired(peerId: String): Boolean {
        return prefs.getBoolean("paired_$peerId", false)
    }

    fun removePeer(peerId: String) {
        prefs.edit()
            .remove("key_$peerId")
            .remove("paired_$peerId")
            .apply()
    }

    fun listPairedPeerIds(): Set<String> {
        return prefs.all.keys
            .filter { it.startsWith("paired_") }
            .map { it.removePrefix("paired_") }
            .toSet()
    }
}
