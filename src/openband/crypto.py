"""Huawei link crypto: auth digests, bonding key, PIN decryption, payload encryption.

The constants are the published values the Huawei link uses for every device; Gadgetbridge
documents them in HuaweiCrypto.java. Nothing here is per-user.
"""

from __future__ import annotations

import hashlib
import hmac
import os

from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

SECRET_KEY_1_V1 = bytes([0x6F, 0x75, 0x6A, 0x79, 0x6D, 0x77, 0x71, 0x34, 0x63, 0x6C, 0x76, 0x39, 0x33, 0x37, 0x38, 0x79])
SECRET_KEY_2_V1 = bytes([0x62, 0x31, 0x30, 0x6A, 0x67, 0x66, 0x64, 0x39, 0x79, 0x37, 0x76, 0x73, 0x75, 0x64, 0x61, 0x39])
SECRET_KEY_1_V23 = bytes([0x55, 0x53, 0x86, 0xFC, 0x63, 0x20, 0x07, 0xAA, 0x86, 0x49, 0x35, 0x22, 0xB8, 0x6A, 0xE2, 0x5C])
SECRET_KEY_2_V23 = bytes([0x33, 0x07, 0x9B, 0xC5, 0x7A, 0x88, 0x6D, 0x3C, 0xF5, 0x61, 0x37, 0x09, 0x6F, 0x22, 0x80, 0x00])

DIGEST_SECRET_V1 = bytes([0x70, 0xFB, 0x6C, 0x24, 0x03, 0x5F, 0xDB, 0x55, 0x2F, 0x38, 0x89, 0x8A, 0xEE, 0xDE, 0x3F, 0x69])
DIGEST_SECRET_V2 = bytes([0x93, 0xAC, 0xDE, 0xF7, 0x6A, 0xCB, 0x09, 0x85, 0x7D, 0xBF, 0xE5, 0x26, 0x1A, 0xAB, 0xCD, 0x78])
DIGEST_SECRET_V3 = bytes([0x9C, 0x27, 0x63, 0xA9, 0xCC, 0xE1, 0x34, 0x76, 0x6D, 0xE3, 0xFF, 0x61, 0x18, 0x20, 0x05, 0x53])

MESSAGE_RESPONSE = b"\x01\x10"
MESSAGE_CHALLENGE = b"\x01\x00"
MESSAGE_CHALLENGE_V4 = b"\x04\x00"

COUNTER_MAX = 0xFFFFFFFF

# Auth modes, as negotiated after LinkParams.
AUTH_MODE_NORMAL = 0x00
AUTH_MODE_HICHAIN_LITE = 0x02
AUTH_MODE_HICHAIN3 = 0x04


def _hmac(key: bytes, msg: bytes) -> bytes:
    return hmac.new(key, msg, hashlib.sha256).digest()


def _sha256(data: bytes) -> bytes:
    return hashlib.sha256(data).digest()


def _hex(data: bytes) -> str:
    return data.hex().upper()


def nonce16() -> bytes:
    return os.urandom(16)


def digest_secret(auth_version: int) -> bytes:
    if auth_version in (1, 4):  # 4: Honor Health devices
        return DIGEST_SECRET_V1
    if auth_version == 2:
        return DIGEST_SECRET_V2
    return DIGEST_SECRET_V3


def _digest(auth_version: int, message: bytes, nonce: bytes) -> bytes:
    step1 = _hmac(digest_secret(auth_version) + message, nonce)
    return _hmac(step1, nonce) + step1


def _digest_hichain_lite(auth_version: int, auth_algo: int, message: bytes, key: bytes, nonce: bytes) -> bytes:
    hash_key = _sha256(_hex(key).encode())
    secret = bytes(a ^ b for a, b in zip(hash_key[:16], digest_secret(auth_version)))
    to_digest = secret + message
    if auth_algo == 0x01:
        step1 = hashlib.pbkdf2_hmac("sha256", _hex(to_digest).encode(), _hex(nonce).encode(), 1000, 32)
    else:
        step1 = _hmac(to_digest, nonce)
    return _hmac(step1, nonce) + step1


def _digest_for(
    message: bytes,
    nonce: bytes,
    *,
    auth_version: int,
    auth_mode: int,
    auth_algo: int,
    key: bytes | None,
) -> bytes:
    """64 bytes; the first 32 go on the wire, the first 16 are the 'first key'."""
    if auth_mode == AUTH_MODE_HICHAIN_LITE:
        if key is None:
            raise ValueError("HiChain Lite needs a key (PIN or secret key)")
        if auth_version == 0x02:
            k = key + message
            return (_hmac(k, nonce) + k).ljust(64, b"\x00")
        return _digest_hichain_lite(auth_version, auth_algo, message, key, nonce)
    if message == MESSAGE_CHALLENGE and auth_version == 4:
        message = MESSAGE_CHALLENGE_V4
    return _digest(auth_version, message, nonce)


def digest_challenge(nonce: bytes, **kw) -> bytes:
    return _digest_for(MESSAGE_CHALLENGE, nonce, **kw)


def digest_response(nonce: bytes, **kw) -> bytes:
    return _digest_for(MESSAGE_RESPONSE, nonce, **kw)


def mac_bond_key(band_mac: str, auth_version: int) -> bytes:
    """Key that wraps our secret key in normal mode, derived from the band's Bluetooth MAC."""
    k1, k2 = (SECRET_KEY_1_V1, SECRET_KEY_2_V1) if auth_version == 1 else (SECRET_KEY_1_V23, SECRET_KEY_2_V23)
    mac_key = (band_mac.replace(":", "").upper() + "0000").encode()
    if len(mac_key) != 16:
        raise ValueError(f"not a MAC address: {band_mac!r}")
    mixed = bytes(((a << 4) ^ b) & 0xFF for a, b in zip(k1, k2))
    mixed_hash = _sha256(mixed)
    final = bytes((h >> 6) ^ m for h, m in zip(mixed_hash, mac_key))
    return _sha256(final)[:16]


# --- symmetric ------------------------------------------------------------------------------


def encrypt(use_gcm: bool, data: bytes, key: bytes, iv: bytes) -> bytes:
    if use_gcm:
        return AESGCM(key).encrypt(iv, data, None)
    padder = padding.PKCS7(128).padder()
    padded = padder.update(data) + padder.finalize()
    enc = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    return enc.update(padded) + enc.finalize()


def decrypt(use_gcm: bool, data: bytes, key: bytes, iv: bytes) -> bytes:
    if use_gcm:
        return AESGCM(key).decrypt(iv, data, None)
    dec = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    padded = dec.update(data) + dec.finalize()
    unpadder = padding.PKCS7(128).unpadder()
    return unpadder.update(padded) + unpadder.finalize()


def next_iv(counter: int) -> tuple[bytes, int]:
    """12 random bytes + the next 4-byte big-endian counter; returns (iv, new counter)."""
    counter = 1 if counter >= COUNTER_MAX else counter + 1
    return os.urandom(12) + counter.to_bytes(4, "big"), counter
