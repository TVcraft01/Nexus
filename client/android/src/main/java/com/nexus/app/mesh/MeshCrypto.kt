package com.nexus.app.mesh

import android.util.Base64
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.PBEKeySpec
import javax.crypto.spec.SecretKeySpec

/**
 * Lightweight AES-256-GCM helper for mesh message encryption.
 */
object MeshCrypto {

    private const val AES_KEY_SIZE_BITS = 256
    private const val GCM_IV_SIZE_BYTES = 12
    private const val GCM_TAG_SIZE_BITS = 128
    private const val ALGORITHM = "AES/GCM/NoPadding"
    private const val PBKDF2_ALGORITHM = "PBKDF2WithHmacSHA256"
    private const val PBKDF2_ITERATIONS = 100_000

    private val secureRandom = SecureRandom()

    /** Generates a fresh 256-bit AES key for a peer pairing. */
    fun generateAesKey(): SecretKey {
        val bytes = ByteArray(32)
        secureRandom.nextBytes(bytes)
        return SecretKeySpec(bytes, "AES")
    }

    /** Derives a 256-bit AES key from a user PIN and a salt. */
    fun deriveKeyFromPin(pin: String, salt: ByteArray): SecretKey {
        val spec = PBEKeySpec(pin.toCharArray(), salt, PBKDF2_ITERATIONS, AES_KEY_SIZE_BITS)
        val factory = javax.crypto.SecretKeyFactory.getInstance(PBKDF2_ALGORITHM)
        val keyBytes = factory.generateSecret(spec).encoded
        return SecretKeySpec(keyBytes, "AES")
    }

    /** Builds a deterministic salt from a peer nodeId. */
    fun saltForNodeId(nodeId: String): ByteArray {
        return MessageDigest.getInstance("SHA-256").run {
            update(nodeId.toByteArray(StandardCharsets.UTF_8))
            digest()
        }
    }

    /** Encrypts [plaintext] with the given [key]. Returns IV || ciphertext (with GCM tag). */
    fun encrypt(key: SecretKey, plaintext: ByteArray): ByteArray {
        val iv = ByteArray(GCM_IV_SIZE_BYTES)
        secureRandom.nextBytes(iv)
        val cipher = Cipher.getInstance(ALGORITHM)
        cipher.init(Cipher.ENCRYPT_MODE, key, GCMParameterSpec(GCM_TAG_SIZE_BITS, iv))
        val ciphertext = cipher.doFinal(plaintext)
        return ByteBuffer.allocate(iv.size + ciphertext.size)
            .put(iv)
            .put(ciphertext)
            .array()
    }

    /** Decrypts a payload that begins with a 12-byte GCM IV. */
    fun decrypt(key: SecretKey, ivAndCiphertext: ByteArray): ByteArray {
        require(ivAndCiphertext.size > GCM_IV_SIZE_BYTES) { "Invalid encrypted payload" }
        val iv = ivAndCiphertext.copyOfRange(0, GCM_IV_SIZE_BYTES)
        val ciphertext = ivAndCiphertext.copyOfRange(GCM_IV_SIZE_BYTES, ivAndCiphertext.size)
        val cipher = Cipher.getInstance(ALGORITHM)
        cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_SIZE_BITS, iv))
        return cipher.doFinal(ciphertext)
    }

    fun secretKeyFromBytes(bytes: ByteArray): SecretKey = SecretKeySpec(bytes, "AES")

    fun encodeKeyBase64(key: SecretKey): String =
        Base64.encodeToString(key.encoded, Base64.NO_WRAP)

    fun decodeKeyBase64(base64: String): SecretKey =
        SecretKeySpec(Base64.decode(base64, Base64.NO_WRAP), "AES")
}
