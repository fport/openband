"""Per-connection state: what LinkParams told us, the session key and the IV counter."""

from __future__ import annotations

import os
from dataclasses import dataclass, field

from . import crypto
from .frame import DEFAULT_SLICE_SIZE
from .tlv import TLV

TAG_ENCRYPTED = 0x7C
TAG_IV = 0x7D
TAG_CIPHERTEXT = 0x7E
TAG_RESULT = 0x7F
RESULT_SUCCESS = 100000


@dataclass
class LinkParams:
    protocol_version: int = 0
    slice_size: int = DEFAULT_SLICE_SIZE
    mtu: int = 0x14
    interval: int = 0
    auth_version: int = 0
    server_nonce: bytes = b""
    device_support_type: int = 0
    auth_algo: int = 0
    bond_state: int = 0
    encrypt_method: int = 0

    @classmethod
    def from_tlv(cls, t: TLV) -> "LinkParams":
        nonce_field = t.get(0x05)
        if len(nonce_field) < 18:
            raise ValueError(f"LinkParams nonce field too short: {nonce_field.hex()}")
        return cls(
            protocol_version=t.byte(0x01, 0),
            slice_size=t.uint(0x02, DEFAULT_SLICE_SIZE),
            mtu=t.uint(0x03, 0x14),
            interval=t.uint(0x04, 0),
            auth_version=nonce_field[1],
            server_nonce=nonce_field[2:18],
            device_support_type=t.byte(0x07, 0),
            auth_algo=t.byte(0x08, 0),
            bond_state=t.byte(0x09, 0),
            encrypt_method=t.byte(0x0C, 0),
        )

    @property
    def uses_hichain(self) -> bool:
        """Support types 1-4 go through security negotiation first; 0 is the plain 'normal' mode."""
        return self.device_support_type in (0x01, 0x02, 0x03, 0x04)


@dataclass
class Session:
    params: LinkParams = field(default_factory=LinkParams)
    secret_key: bytes | None = None
    counter: int = 0
    auth_mode: int = crypto.AUTH_MODE_NORMAL
    authenticated: bool = False

    @property
    def use_gcm(self) -> bool:
        return self.params.encrypt_method == 0x01 or self.params.device_support_type == 0x04

    def iv(self) -> bytes:
        if self.params.device_support_type == 0x04:
            return os.urandom(16)
        iv, self.counter = crypto.next_iv(self.counter)
        return iv

    def seal(self, body: TLV) -> TLV:
        if self.secret_key is None:
            raise RuntimeError("no session key yet")
        iv = self.iv()
        ct = crypto.encrypt(self.use_gcm, body.serialize(), self.secret_key, iv)
        return TLV().put(TAG_ENCRYPTED, 0x01, size=1).put(TAG_IV, iv).put(TAG_CIPHERTEXT, ct)

    def open(self, body: TLV) -> TLV:
        if TAG_ENCRYPTED not in body or body.byte(TAG_ENCRYPTED) != 1:
            return body
        if self.secret_key is None:
            raise RuntimeError("encrypted message before we have a key")
        plain = crypto.decrypt(self.use_gcm, body.get(TAG_CIPHERTEXT), self.secret_key, body.get(TAG_IV))
        return TLV.parse(plain)
