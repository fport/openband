"""Link framing: `5A | len(2) | slice | [flag] | service | command | body | crc16(2)`.

`len` counts every byte from the slice byte up to (not including) the CRC. A message that does
not fit in one slice is split; slice byte 1 opens it (and carries service and command), 2
continues it and 3 closes it, each followed by a running flag byte. Slice byte 0 means unsliced.
"""

from __future__ import annotations

from dataclasses import dataclass

MAGIC = 0x5A
DEFAULT_SLICE_SIZE = 0xF4


class FrameError(ValueError):
    pass


def crc16(data: bytes, crc: int = 0x0000) -> int:
    """CRC-16/CCITT (poly 0x1021, no reflection), init 0: CRC-16/XMODEM."""
    for b in data:
        crc = ((crc >> 8) | (crc << 8)) & 0xFFFF
        crc ^= b
        crc ^= (crc & 0xFF) >> 4
        crc ^= (crc << 12) & 0xFFFF
        crc ^= ((crc & 0xFF) << 5) & 0xFFFF
    return crc & 0xFFFF


def _with_crc(head: bytes) -> bytes:
    return head + crc16(head).to_bytes(2, "big")


def encode(service: int, command: int, body: bytes, slice_size: int = DEFAULT_SLICE_SIZE) -> list[bytes]:
    """Frame one message; returns one or more packets to write in order."""
    header, footer = 5, 2
    max_body = slice_size - header - footer
    if max_body <= 2:
        raise FrameError(f"slice size {slice_size} is too small")
    count = -(-(len(body) + 2) // max_body)  # ceil
    if count == 1:
        head = bytes([MAGIC]) + (len(body) + 3).to_bytes(2, "big") + bytes([0, service, command]) + body
        return [_with_crc(head)]

    packets = []
    pos = 0
    for i in range(count):
        size = min(slice_size, len(body) - pos + header + footer)
        content = size - header - footer
        kind = 3 if i == count - 1 else (1 if i == 0 else 2)
        head = bytearray([MAGIC]) + (size - header).to_bytes(2, "big") + bytes([kind, i & 0xFF])
        if i == 0:
            head += bytes([service, command])
            content -= 2
        head += body[pos : pos + content]
        pos += content
        packets.append(_with_crc(bytes(head)))
    return packets


@dataclass
class Message:
    service: int
    command: int
    body: bytes


class Reassembler:
    """Feed raw notification bytes; collect complete messages.

    Handles a frame split across notifications, several frames in one notification, and
    sliced messages spread over several frames.
    """

    def __init__(self) -> None:
        self._buf = bytearray()
        self._sliced = bytearray()

    def feed(self, data: bytes) -> list[Message]:
        self._buf += data
        out: list[Message] = []
        while True:
            if not self._buf:
                break
            if self._buf[0] != MAGIC:
                bad = self._buf.hex()
                self._buf.clear()
                self._sliced.clear()
                raise FrameError(f"bad magic: {bad}")
            if len(self._buf) < 3:
                break
            length = int.from_bytes(self._buf[1:3], "big")
            total = 3 + length + 2
            if len(self._buf) < total:
                break
            frame = bytes(self._buf[:total])
            del self._buf[:total]
            expected = int.from_bytes(frame[-2:], "big")
            actual = crc16(frame[:-2])
            if expected != actual:
                self._sliced.clear()
                raise FrameError(f"crc mismatch {actual:04x} != {expected:04x} in {frame.hex()}")
            kind = frame[3]
            if kind in (1, 2, 3):
                payload = frame[5:-2]
                if kind == 1:
                    self._sliced = bytearray(payload)
                else:
                    self._sliced += payload
                if kind != 3:
                    continue
                payload = bytes(self._sliced)
                self._sliced.clear()
            else:
                payload = frame[4:-2]
            if len(payload) < 2:
                raise FrameError(f"message too short: {payload.hex()}")
            out.append(Message(payload[0], payload[1], payload[2:]))
        return out
