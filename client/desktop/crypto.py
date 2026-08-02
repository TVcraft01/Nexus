"""Lightweight AES-256-GCM helper matching Android MeshCrypto.

Android implementation details:
- AES/GCM/NoPadding
- 12-byte IV, 128-bit GCM tag
- 100_000 PBKDF2 iterations with HMAC-SHA256
- Key derived from user PIN + SHA-256(nodeId) salt
- Encrypted frame format: IV || ciphertext (ciphertext includes GCM tag)
"""

from __future__ import annotations

import base64
import hashlib
import os
import secrets
from typing import Optional

from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.pbkdf2 import PBKDF2HMAC


GCM_IV_SIZE = 12
GCM_TAG_BITS = 128
PBKDF2_ITERATIONS = 100_000
KEY_SIZE_BYTES = 32


def generate_aes_key() -> bytes:
    """Generate a fresh 256-bit AES key for a peer pairing."""
    return secrets.token_bytes(KEY_SIZE_BYTES)


def salt_for_node_id(node_id: str) -> bytes:
    """Build a deterministic salt from a peer node id (SHA-256 of UTF-8 bytes)."""
    return hashlib.sha256(node_id.encode("utf-8")).digest()


def derive_key_from_pin(pin: str, salt: bytes) -> bytes:
    """Derive a 256-bit AES key from a user PIN and a salt."""
    kdf = PBKDF2HMAC(
        algorithm=hashes.SHA256(),
        length=KEY_SIZE_BYTES,
        salt=salt,
        iterations=PBKDF2_ITERATIONS,
    )
    return kdf.derive(pin.encode("utf-8"))


def encrypt(key: bytes, plaintext: bytes) -> bytes:
    """Encrypt plaintext. Returns IV || ciphertext (ciphertext includes GCM tag)."""
    iv = secrets.token_bytes(GCM_IV_SIZE)
    aesgcm = AESGCM(key)
    ciphertext = aesgcm.encrypt(iv, plaintext, None)
    return iv + ciphertext


def decrypt(key: bytes, iv_and_ciphertext: bytes) -> bytes:
    """Decrypt a payload that begins with a 12-byte GCM IV."""
    if len(iv_and_ciphertext) <= GCM_IV_SIZE:
        raise ValueError("Invalid encrypted payload")
    iv = iv_and_ciphertext[:GCM_IV_SIZE]
    ciphertext = iv_and_ciphertext[GCM_IV_SIZE:]
    aesgcm = AESGCM(key)
    return aesgcm.decrypt(iv, ciphertext, None)


def encode_key_base64(key: bytes) -> str:
    return base64.b64encode(key).decode("ascii")


def decode_key_base64(encoded: str) -> bytes:
    return base64.b64decode(encoded.encode("ascii"))
