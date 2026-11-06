"""Huawei TLV: one-byte tag, big-endian base-128 varint length, value.

Tags with the high bit set (0x80 and up) hold nested TLVs. Integers are big-endian.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Iterator


class TLVError(ValueError):
    pass


class MissingTag(TLVError):
    def __init__(self, tag: int):
        super().__init__(f"missing tag 0x{tag:02x}")
        self.tag = tag


def encode_varint(value: int) -> bytes:
    """Big-endian base-128: the high bit marks 'more bytes follow' (not protobuf order)."""
    if value < 0:
        raise TLVError("varint must be non-negative")
    groups = [value & 0x7F]
    value >>= 7
    while value:
        groups.append((value & 0x7F) | 0x80)
        value >>= 7
    return bytes(reversed(groups))


def decode_varint(buf: bytes, offset: int) -> tuple[int, int]:
    """Return (value, bytes consumed)."""
    value = 0
    start = offset
    while True:
        if offset >= len(buf):
            raise TLVError("truncated varint")
        b = buf[offset]
        offset += 1
        value = (value << 7) | (b & 0x7F)
        if not b & 0x80:
            return value, offset - start


@dataclass
class TLV:
    items: list[tuple[int, bytes]] = field(default_factory=list)

    # --- building -------------------------------------------------------------------------

    def put(self, tag: int, value: "bytes | int | bool | str | TLV | None" = b"", *, size: int | None = None) -> "TLV":
        """Append a tag. Ints need an explicit size (1, 2, 4 or 8 bytes); bools are one byte."""
        if value is None:
            return self
        if isinstance(value, TLV):
            raw = value.serialize()
        elif isinstance(value, bool):
            raw = b"\x01" if value else b"\x00"
        elif isinstance(value, int):
            if size is None:
                raise TLVError("int values need size=")
            raw = value.to_bytes(size, "big", signed=value < 0)
        elif isinstance(value, str):
            raw = value.encode()
        else:
            raw = bytes(value)
        self.items.append((tag & 0xFF, raw))
        return self

    def serialize(self) -> bytes:
        out = bytearray()
        for tag, value in self.items:
            out.append(tag)
            out += encode_varint(len(value))
            out += value
        return bytes(out)

    # --- parsing --------------------------------------------------------------------------

    @classmethod
    def parse(cls, buf: bytes) -> "TLV":
        items: list[tuple[int, bytes]] = []
        i = 0
        while i < len(buf):
            tag = buf[i]
            i += 1
            # Encrypted payloads can end with one stray zero byte; ignore it.
            if i == len(buf) and tag == 0:
                break
            size, used = decode_varint(buf, i)
            i += used
            if size > len(buf) - i:
                raise TLVError(f"tag 0x{tag:02x} claims {size} bytes, {len(buf) - i} left")
            items.append((tag, bytes(buf[i : i + size])))
            i += size
        return cls(items)

    # --- reading --------------------------------------------------------------------------

    def __contains__(self, tag: int) -> bool:
        return any(t == tag for t, _ in self.items)

    def __iter__(self) -> Iterator[tuple[int, bytes]]:
        return iter(self.items)

    def get(self, tag: int, default: bytes | None = None) -> bytes:
        for t, v in self.items:
            if t == tag:
                return v
        if default is not None:
            return default
        raise MissingTag(tag)

    def get_all(self, tag: int) -> list[bytes]:
        return [v for t, v in self.items if t == tag]

    def uint(self, tag: int, default: int | None = None) -> int:
        """Big-endian unsigned int of whatever width the band sent."""
        if tag not in self:
            if default is not None:
                return default
            raise MissingTag(tag)
        return int.from_bytes(self.get(tag), "big")

    def byte(self, tag: int, default: int | None = None) -> int:
        if tag not in self:
            if default is not None:
                return default
            raise MissingTag(tag)
        return self.get(tag)[0]

    def string(self, tag: int, default: str | None = None) -> str:
        if tag not in self:
            if default is not None:
                return default
            raise MissingTag(tag)
        return self.get(tag).decode("utf-8", errors="replace")

    def child(self, tag: int) -> "TLV":
        return TLV.parse(self.get(tag))

    def children(self, tag: int) -> list["TLV"]:
        return [TLV.parse(v) for v in self.get_all(tag)]

    def __repr__(self) -> str:
        inner = " ".join(f"{t:02x}={v.hex() or '-'}" for t, v in self.items)
        return f"TLV({inner})"
