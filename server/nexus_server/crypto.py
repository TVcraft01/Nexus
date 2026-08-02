# Crypto helpers - compat layer wrapping Rust core or Python fallback

from __future__ import annotations

import base64
import hashlib
import secrets

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC
    from cryptography.hazmat.primitives import hashes
    _CRYPTO_AVAILABLE = True
except ImportError:
    _CRYPTO_AVAILABLE = False

GCM_IV_SIZE = 12
KEY_SIZE_BYTES = 32
PBKDF2_ITERATIONS = 100_000


def salt_for_node_id(node_id: str) -> bytes:
    return hashlib.sha256(node_id.encode("utf-8")).digest()


def derive_key_from_pin(pin: str, salt: bytes) -> bytes:
    if _CRYPTO_AVAILABLE:
        kdf = PBKDF2HMAC(
            algorithm=hashes.SHA256(),
            length=KEY_SIZE_BYTES,
            salt=salt,
            iterations=PBKDF2_ITERATIONS,
        )
        return kdf.derive(pin.encode("utf-8"))
    # Fallback: simple SHA-256 stretching
    key = hashlib.pbkdf2_hmac("sha256", pin.encode(), salt, PBKDF2_ITERATIONS, KEY_SIZE_BYTES)
    return key


def encrypt(key: bytes, plaintext: bytes) -> bytes:
    if _CRYPTO_AVAILABLE:
        iv = secrets.token_bytes(GCM_IV_SIZE)
        aesgcm = AESGCM(key)
        ciphertext = aesgcm.encrypt(iv, plaintext, None)
        return iv + ciphertext
    raise RuntimeError("Cryptography library required for encryption")


def decrypt(key: bytes, iv_and_ct: bytes) -> bytes:
    if _CRYPTO_AVAILABLE:
        iv = iv_and_ct[:GCM_IV_SIZE]
        ct = iv_and_ct[GCM_IV_SIZE:]
        aesgcm = AESGCM(key)
        return aesgcm.decrypt(iv, ct, None)
    raise RuntimeError("Cryptography library required for decryption")


def encode_key_base64(key: bytes) -> str:
    return base64.b64encode(key).decode("ascii")


def decode_key_base64(encoded: str) -> bytes:
    return base64.b64decode(encoded.encode("ascii"))
