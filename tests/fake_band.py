"""A simulated Huawei band: the band side of the handshake and a few data commands.

It answers in 20-byte notifications so the client's reassembly gets exercised too.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field

from openband import commands as cmd
from openband import crypto, frame
from openband.session import TAG_CIPHERTEXT, TAG_ENCRYPTED, TAG_IV, TAG_RESULT
from openband.tlv import TLV


@dataclass
class BandConfig:
    support_type: int = 0x02
    auth_version: int = 0x03
    auth_algo: int = 0x00
    encrypt_method: int = 0x00
    negotiated_auth_type: int = 0x02
    pin: bytes = b"482913"
    mac: str = "A4:C1:38:5D:7E:9F"
    counter: int = 0x100
    bond_status: int = 0
    answer_bond: bool = True


@dataclass
class FakeBand:
    cfg: BandConfig = field(default_factory=BandConfig)
    client_key: bytes | None = None  # only for HiChain Lite v2, where the challenge uses our key
    session_key: bytes | None = None
    counter: int = 0
    seen: list[tuple[int, int]] = field(default_factory=list)
    receiver: object = None
    _server_nonce: bytes = b"\x5a" * 16
    _client_nonce: bytes = b""
    _first_key: bytes = b""
    steps_records: list[TLV] = field(default_factory=list)
    sleep_records: list[TLV] = field(default_factory=list)

    max_write = 244

    def __post_init__(self):
        self._r = frame.Reassembler()

    # transport side -----------------------------------------------------------------------

    def set_receiver(self, receiver):
        self.receiver = receiver

    async def write(self, data: bytes) -> None:
        for m in self._r.feed(data):
            self.seen.append((m.service, m.command))
            reply = self.handle(m.service, m.command, TLV.parse(m.body))
            if reply is not None:
                encrypted, body = reply
                if encrypted:
                    body = self._seal(body)
                stream = b"".join(frame.encode(m.service, m.command, body.serialize()))
                for i in range(0, len(stream), 20):
                    asyncio.get_running_loop().call_soon(self.receiver, stream[i : i + 20])

    # crypto --------------------------------------------------------------------------------

    @property
    def gcm(self):
        return self.cfg.encrypt_method == 1 or self.cfg.support_type == 4

    def _seal(self, body: TLV) -> TLV:
        iv, self.counter = crypto.next_iv(self.counter)
        ct = crypto.encrypt(self.gcm, body.serialize(), self.session_key, iv)
        return TLV().put(TAG_ENCRYPTED, 1, size=1).put(TAG_IV, iv).put(TAG_CIPHERTEXT, ct)

    def _open(self, t: TLV) -> TLV:
        if TAG_ENCRYPTED not in t:
            raise AssertionError("expected an encrypted request")
        return TLV.parse(crypto.decrypt(self.gcm, t.get(TAG_CIPHERTEXT), self.session_key, t.get(TAG_IV)))

    def _kw(self):
        mode = crypto.AUTH_MODE_HICHAIN_LITE if self.cfg.support_type in (1, 2, 3, 4) else crypto.AUTH_MODE_NORMAL
        key = None
        if mode == crypto.AUTH_MODE_HICHAIN_LITE:
            key = self.client_key if self.cfg.auth_version == 2 else self.cfg.pin
        return dict(auth_version=self.cfg.auth_version, auth_mode=mode, auth_algo=self.cfg.auth_algo, key=key)

    # protocol ------------------------------------------------------------------------------

    def handle(self, sid: int, cid: int, t: TLV):
        c = self.cfg
        if (sid, cid) == (1, cmd.LINK_PARAMS):
            return False, (TLV()
                .put(0x01, 2, size=1).put(0x02, 0xF4, size=2).put(0x03, 0x200, size=2).put(0x04, 0, size=2)
                .put(0x05, bytes([0, c.auth_version]) + self._server_nonce)
                .put(0x07, c.support_type, size=1).put(0x08, c.auth_algo, size=1)
                .put(0x09, 0, size=1).put(0x0C, c.encrypt_method, size=1))
        if (sid, cid) == (1, cmd.SECURITY_NEGOTIATION):
            return False, TLV().put(0x02, c.negotiated_auth_type, size=1)
        if (sid, cid) == (1, cmd.PIN_CODE):
            iv = b"\x11" * (12 if c.encrypt_method == 1 else 16)
            ct = crypto.encrypt(c.encrypt_method == 1, c.pin, crypto.digest_secret(c.auth_version), iv)
            return False, TLV().put(0x01, ct).put(0x02, iv)
        if (sid, cid) == (1, cmd.AUTH):
            nonce = self._server_nonce + t.get(0x02)[2:]
            chal = crypto.digest_challenge(nonce, **self._kw())
            if t.get(0x01) != chal[:32]:
                return False, TLV().put(TAG_RESULT, 0x0001_0001, size=4)
            self._first_key = chal[:16]
            return False, TLV().put(0x01, crypto.digest_response(nonce, **self._kw())[:32])
        if (sid, cid) == (1, cmd.BOND_PARAMS):
            self.counter = c.counter
            return False, TLV().put(0x01, c.bond_status, size=1).put(0x09, c.counter, size=4)
        if (sid, cid) == (1, cmd.BOND):
            hichain = self._kw()["auth_mode"] == crypto.AUTH_MODE_HICHAIN_LITE
            wrap = self._first_key if hichain else crypto.mac_bond_key(c.mac, c.auth_version)
            self.session_key = crypto.decrypt(c.encrypt_method == 1, t.get(0x06), wrap, t.get(0x07))
            self.counter = int.from_bytes(t.get(0x07)[12:], "big")
            return (False, TLV().put(TAG_RESULT, 100000, size=4)) if c.answer_bond else None

        req = self._open(t)
        if (sid, cid) == (1, cmd.PRODUCT_INFO):
            return True, TLV().put(0x07, "1.0.1.36").put(0x0A, "FRA-B19 ").put(0x09, "SN123")
        if (sid, cid) == (1, cmd.BATTERY):
            return True, TLV().put(0x01, 77, size=1)
        if (sid, cid) == (1, cmd.TIME):
            assert 0x01 in req and 0x02 in req
            return True, TLV().put(TAG_RESULT, 100000, size=4)
        if (sid, cid) == (7, cmd.FITNESS_TOTALS):
            day = TLV().put(0x05, 1234, size=4).put(0x06, 56, size=2).put(0x07, 900, size=4)
            return True, TLV().put(0x81, TLV().put(0x83, day))
        if (sid, cid) == (7, cmd.STEP_COUNT):
            return True, TLV().put(0x81, TLV().put(0x02, len(self.steps_records), size=2))
        if (sid, cid) == (7, cmd.STEP_DATA):
            return True, self.steps_records[req.child(0x81).uint(0x02)]
        if (sid, cid) == (7, cmd.SLEEP_COUNT):
            if not self.sleep_records:
                return True, TLV().put(TAG_RESULT, 0x0001_E079, size=4)
            return True, TLV().put(0x81, TLV().put(0x02, len(self.sleep_records), size=2))
        if (sid, cid) == (7, cmd.SLEEP_DATA):
            return True, self.sleep_records[req.child(0x81).uint(0x02)]
        raise AssertionError(f"fake band got unexpected {sid:02x}/{cid:02x}")
