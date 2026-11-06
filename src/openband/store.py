"""What Openband remembers per band: our session key and the identity we present to it.

Kept in ~/.config/openband/bands.json (or $OPENBAND_HOME/bands.json), readable only by you.
The secret key is created here, on your machine; no server is involved.
"""

from __future__ import annotations

import json
import os
import secrets
from dataclasses import asdict, dataclass
from pathlib import Path


def home() -> Path:
    return Path(os.environ.get("OPENBAND_HOME", Path.home() / ".config" / "openband"))


@dataclass
class BandRecord:
    address: str
    name: str = ""
    secret_key: str = ""  # 16 bytes, hex; ours, handed to the band when bonding
    client_mac: str = ""  # a made-up MAC we introduce ourselves with
    device_uuid: str = ""  # a made-up phone id for security negotiation
    band_mac: str = ""  # the band's own Bluetooth MAC; only normal-mode bonding needs it
    bonded: bool = False

    @classmethod
    def new(cls, address: str, name: str = "") -> "BandRecord":
        tail = ":".join(f"{b:02X}" for b in secrets.token_bytes(3))
        return cls(
            address=address,
            name=name,
            secret_key=secrets.token_hex(16).upper(),
            client_mac=f"FF:FF:FF:{tail}",
            device_uuid=secrets.token_hex(16).upper(),
        )

    @property
    def key(self) -> bytes:
        return bytes.fromhex(self.secret_key)

    @property
    def client_serial(self) -> bytes:
        return self.client_mac.replace(":", "")[6:12].encode()


class Store:
    def __init__(self, path: Path | None = None):
        self.path = path or home() / "bands.json"

    def _load(self) -> dict[str, dict]:
        if not self.path.exists():
            return {}
        return json.loads(self.path.read_text())

    def get(self, address: str) -> BandRecord | None:
        raw = self._load().get(address)
        return BandRecord(**raw) if raw else None

    def all(self) -> list[BandRecord]:
        return [BandRecord(**r) for r in self._load().values()]

    def get_or_create(self, address: str, name: str = "") -> BandRecord:
        return self.get(address) or BandRecord.new(address, name)

    def save(self, rec: BandRecord) -> None:
        data = self._load()
        data[rec.address] = asdict(rec)
        self._write(data)

    def remove(self, address: str) -> None:
        data = self._load()
        data.pop(address, None)
        self._write(data)

    def _write(self, data: dict) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2) + "\n")
        os.chmod(tmp, 0o600)
        tmp.replace(self.path)
