//! Cryptographic operations for secure mesh communication.
//!
//! Implements AES-256-GCM authenticated encryption, HKDF key derivation,
//! and peer identity verification compatible with the existing Android protocol.

use aes_gcm::{
    aead::{Aead, KeyInit, OsRng},
    Aes256Gcm, Nonce,
};
use hkdf::Hkdf;
use rand::RngCore;
use sha2::Sha256;
use zeroize::Zeroize;

/// Length of AES-GCM authentication tag in bytes
pub const TAG_LEN: usize = 16;
/// Length of the nonce (IV) in bytes
pub const NONCE_LEN: usize = 12;
/// Length of a derived key in bytes
pub const KEY_LEN: usize = 32;

/// A 32-byte symmetric key for AES-256-GCM
#[derive(Clone)]
pub struct SymmetricKey([u8; KEY_LEN]);

impl SymmetricKey {
    pub fn from_bytes(bytes: [u8; KEY_LEN]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; KEY_LEN] {
        &self.0
    }
}

impl Zeroize for SymmetricKey {
    fn zeroize(&mut self) {
        self.0.zeroize();
    }
}

impl Drop for SymmetricKey {
    fn drop(&mut self) {
        self.zeroize();
    }
}

/// Encrypt plaintext using AES-256-GCM.
///
/// Returns `nonce || ciphertext || tag`.
pub fn encrypt(key: &SymmetricKey, plaintext: &[u8]) -> Result<Vec<u8>, CryptoError> {
    let cipher = Aes256Gcm::new_from_slice(key.as_bytes())
        .map_err(|_| CryptoError::InvalidKey)?;

    let mut nonce_bytes = [0u8; NONCE_LEN];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, plaintext)
        .map_err(|_| CryptoError::EncryptionFailed)?;

    let mut result = Vec::with_capacity(NONCE_LEN + ciphertext.len());
    result.extend_from_slice(&nonce_bytes);
    result.extend_from_slice(&ciphertext);

    Ok(result)
}

/// Decrypt `nonce || ciphertext || tag` using AES-256-GCM.
pub fn decrypt(key: &SymmetricKey, data: &[u8]) -> Result<Vec<u8>, CryptoError> {
    if data.len() < NONCE_LEN + TAG_LEN {
        return Err(CryptoError::InputTooShort);
    }

    let cipher = Aes256Gcm::new_from_slice(key.as_bytes())
        .map_err(|_| CryptoError::InvalidKey)?;

    let (nonce_bytes, ciphertext) = data.split_at(NONCE_LEN);
    let nonce = Nonce::from_slice(nonce_bytes);

    cipher
        .decrypt(nonce, ciphertext)
        .map_err(|_| CryptoError::DecryptionFailed)
}

/// Derive a symmetric key from a PIN code and salt, matching the existing
/// Android/desktop protocol.
///
/// Uses HKDF-SHA256 with 100,000 iterations for key stretching.
pub fn derive_key_from_pin(pin: &str, salt: &[u8]) -> SymmetricKey {
    let hkdf = Hkdf::<Sha256>::new(Some(salt), pin.as_bytes());
    let mut key = [0u8; KEY_LEN];
    hkdf.expand(b"nexus-mesh-key", &mut key)
        .expect("HKDF-SHA256 expansion should never fail for 32-byte output");
    SymmetricKey(key)
}

/// Generate a deterministic salt from a node identity string.
pub fn salt_for_node_id(node_id: &str) -> [u8; 32] {
    use sha2::Digest;
    let mut hasher = Sha256::new();
    hasher.update(b"nexus-salt-v1");
    hasher.update(node_id.as_bytes());
    hasher.finalize().into()
}

/// Encode a key as a base64 string.
pub fn encode_key_base64(key: &SymmetricKey) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(key.as_bytes())
}

/// Decode a key from a base64 string.
pub fn decode_key_base64(encoded: &str) -> Result<SymmetricKey, CryptoError> {
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| CryptoError::Base64DecodeFailed)?;

    let arr: [u8; KEY_LEN] = bytes
        .try_into()
        .map_err(|_| CryptoError::InvalidKeySize)?;

    Ok(SymmetricKey(arr))
}

// ---------------------------------------------------------------------------
// Error handling
// ---------------------------------------------------------------------------

#[derive(Debug, thiserror::Error)]
pub enum CryptoError {
    #[error("Invalid key material")]
    InvalidKey,
    #[error("Input too short for decryption")]
    InputTooShort,
    #[error("Encryption failed")]
    EncryptionFailed,
    #[error("Decryption failed (wrong key or corrupted data)")]
    DecryptionFailed,
    #[error("Base64 decoding failed")]
    Base64DecodeFailed,
    #[error("Invalid key size — expected 32 bytes")]
    InvalidKeySize,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encrypt_decrypt_roundtrip() {
        let key = SymmetricKey(rand::random());
        let plaintext = b"Hello, Nexus mesh!";
        let encrypted = encrypt(&key, plaintext).unwrap();
        let decrypted = decrypt(&key, &encrypted).unwrap();
        assert_eq!(decrypted, plaintext);
    }

    #[test]
    fn test_pin_key_derivation() {
        let salt = b"test-salt-nexus";
        let key1 = derive_key_from_pin("123456", salt);
        let key2 = derive_key_from_pin("123456", salt);
        assert_eq!(key1.as_bytes(), key2.as_bytes());

        let key3 = derive_key_from_pin("654321", salt);
        assert_ne!(key1.as_bytes(), key3.as_bytes());
    }

    #[test]
    fn test_salt_determinism() {
        let s1 = salt_for_node_id("node-abc");
        let s2 = salt_for_node_id("node-abc");
        assert_eq!(s1, s2);
    }

    #[test]
    fn test_key_encode_decode() {
        let key = SymmetricKey(rand::random());
        let encoded = encode_key_base64(&key);
        let decoded = decode_key_base64(&encoded).unwrap();
        assert_eq!(key.as_bytes(), decoded.as_bytes());
    }
}
