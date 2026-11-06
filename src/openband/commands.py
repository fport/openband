"""Request builders and response parsers for the commands Openband uses.

Service 0x01 is device config (link, auth, bond, product info, time, battery); service 0x07 is
fitness data (totals, per-minute samples, sleep).
"""

from __future__ import annotations

import datetime as dt
import logging
from dataclasses import dataclass, field

from .tlv import TLV

log = logging.getLogger("openband.commands")

DEVICE_CONFIG = 0x01
FITNESS = 0x07


@dataclass
class Request:
    service: int
    command: int
    tlv: TLV
    encrypted: bool = True
    expects_reply: bool = True

    @property
    def key(self) -> tuple[int, int]:
        return self.service, self.command


# --- device config: link and auth (never encrypted) -------------------------------------------

LINK_PARAMS = 0x01
SUPPORTED_SERVICES = 0x02
TIME = 0x05
PRODUCT_INFO = 0x07
BATTERY = 0x08
BOND = 0x0E
BOND_PARAMS = 0x0F
AUTH = 0x13
BATTERY_CHANGED = 0x27
PIN_CODE = 0x2C
SECURITY_NEGOTIATION = 0x33


def link_params() -> Request:
    return Request(DEVICE_CONFIG, LINK_PARAMS, TLV().put(0x01).put(0x02).put(0x03).put(0x04), encrypted=False)


def security_negotiation(auth_mode: int, device_uuid: bytes, encrypt_method: int, phone_model: str = "iPhone") -> Request:
    t = TLV().put(0x01, auth_mode, size=1)
    if auth_mode in (0x02, 0x04):
        t.put(0x02, 0x01, size=1)  # 1: fresh pairing, not a reconnect
    t.put(0x05, device_uuid).put(0x03, 0x01, size=1).put(0x04, 0x00, size=1)
    if auth_mode == 0x04:
        t.put(0x06).put(0x07, phone_model)
    if encrypt_method == 0x01:
        t.put(0x0D, 0x01, size=1)
    return Request(DEVICE_CONFIG, SECURITY_NEGOTIATION, t, encrypted=False)


HICHAIN_FULL = 0x0186A0


def parse_security_negotiation(t: TLV) -> int:
    """Return the negotiated auth type: 1 or 2 mean HiChain Lite, 0x186A0 or HiChain3 mean full HiChain."""
    auth_type = -1
    pw = -1
    if 0x01 in t:
        if t.byte(0x01) == 0x01:
            auth_type = HICHAIN_FULL
        if t.byte(0x01) == 0x04:
            pw = 4
    if 0x02 in t:
        auth_type = t.byte(0x02)
        if pw != -1:
            auth_type ^= pw
    if 0x7F in t:
        auth_type = t.get(0x7F)[0]
    return auth_type


def is_hichain3(auth_type: int) -> bool:
    return (auth_type ^ 0x01) == 0x04 or (auth_type ^ 0x02) == 0x04


def pin_code() -> Request:
    return Request(DEVICE_CONFIG, PIN_CODE, TLV().put(0x01), encrypted=False)


def auth(challenge: bytes, auth_version: int, client_nonce: bytes, auth_mode: int, auth_algo: int) -> Request:
    t = TLV().put(0x01, challenge).put(0x02, auth_version.to_bytes(2, "big") + client_nonce)
    if auth_mode == 0x02:
        t.put(0x03, auth_algo, size=1)
    return Request(DEVICE_CONFIG, AUTH, t, encrypted=False)


def bond_params(client_serial: bytes, client_mac: bytes) -> Request:
    t = TLV().put(0x01).put(0x03, client_serial).put(0x04, 0x02, size=1).put(0x05).put(0x07, client_mac).put(0x09)
    return Request(DEVICE_CONFIG, BOND_PARAMS, t, encrypted=False)


def bond(client_serial: bytes, wrapped_key: bytes, iv: bytes) -> Request:
    t = TLV().put(0x01).put(0x03, 0x00, size=1).put(0x05, client_serial).put(0x06, wrapped_key).put(0x07, iv)
    return Request(DEVICE_CONFIG, BOND, t, encrypted=False)


# --- device config: after auth ---------------------------------------------------------------

KNOWN_SERVICES = bytes([
    0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
    0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1D, 0x20, 0x22, 0x23,
    0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x30, 0x32, 0x33, 0x34, 0x35,
])


def supported_services() -> Request:
    return Request(DEVICE_CONFIG, SUPPORTED_SERVICES, TLV().put(0x01, KNOWN_SERVICES))


def parse_supported_services(t: TLV) -> list[int]:
    flags = t.get(0x02, b"")
    return [s for s, on in zip(KNOWN_SERVICES, flags) if on]


def product_info() -> Request:
    t = TLV()
    for tag in (0x01, 0x02, 0x07, 0x09, 0x0A, 0x11, 0x12, 0x16, 0x1A, 0x1D, 0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23):
        t.put(tag)
    return Request(DEVICE_CONFIG, PRODUCT_INFO, t)


@dataclass
class ProductInfo:
    model: str
    software_version: str
    hardware_version: str | None
    serial_number: str | None
    device_name: str | None


def parse_product_info(t: TLV) -> ProductInfo:
    def opt(tag: int) -> str | None:
        return t.string(tag) if tag in t else None

    return ProductInfo(
        model=t.string(0x0A, "").strip(),
        software_version=t.string(0x07, ""),
        hardware_version=opt(0x03),
        serial_number=opt(0x09),
        device_name=opt(0x11),
    )


def time_and_zone(now: dt.datetime) -> tuple[int, int]:
    """(unix seconds, packed zone) with the band's encoding: hours byte (+128 when west of UTC)
    and a minutes byte that keeps Java's sign on negative half-hour zones."""
    offset = int(now.utcoffset().total_seconds()) if now.utcoffset() else 0
    hours = (-offset // 3600 + 128) if offset < 0 else offset // 3600
    total_minutes = int(offset / 60)
    minutes = total_minutes - int(total_minutes / 60) * 60
    return int(now.timestamp()), ((hours & 0xFF) << 8) | (minutes & 0xFF)


def set_time(now: dt.datetime | None = None) -> Request:
    now = now or dt.datetime.now().astimezone()
    ts, zone = time_and_zone(now)
    return Request(DEVICE_CONFIG, TIME, TLV().put(0x01, ts, size=4).put(0x02, zone, size=2))


def battery() -> Request:
    return Request(DEVICE_CONFIG, BATTERY, TLV().put(0x01))


def parse_battery(t: TLV) -> int:
    return t.byte(0x01)


# --- fitness ---------------------------------------------------------------------------------

FITNESS_TOTALS = 0x03
STEP_COUNT = 0x0A
STEP_DATA = 0x0B
SLEEP_COUNT = 0x0C
SLEEP_DATA = 0x0D


def fitness_totals() -> Request:
    return Request(FITNESS, FITNESS_TOTALS, TLV().put(0x01))


@dataclass
class Totals:
    steps: int = 0
    calories: int = 0
    distance_m: int = 0


def parse_fitness_totals(t: TLV) -> Totals:
    out = Totals()
    for c in t.child(0x81).children(0x83):
        out.steps += c.uint(0x05, 0)
        out.calories += c.uint(0x06, 0)
        out.distance_m += c.uint(0x07, 0)
    return out


def message_count(command: int, start: int, end: int) -> Request:
    return Request(FITNESS, command, TLV().put(0x81).put(0x03, start, size=4).put(0x04, end, size=4))


def parse_message_count(t: TLV) -> int:
    return t.child(0x81).uint(0x02)


def message_data(command: int, index: int) -> Request:
    return Request(FITNESS, command, TLV().put(0x81, TLV().put(0x02, index, size=2)))


@dataclass
class MinuteSample:
    """One minute of activity. Fields the band did not send are None."""

    timestamp: int
    steps: int | None = None
    calories: int | None = None
    distance_m: int | None = None
    heart_rate: int | None = None
    spo2: int | None = None
    resting_heart_rate: int | None = None
    unknown: dict[str, int] = field(default_factory=dict)


_ONE_BYTE_FIELDS = {0x20, 0x40}
_BITMAP1 = {0x02: "steps", 0x04: "calories", 0x08: "distance_m", 0x40: "heart_rate"}
_BITMAP2 = {0x01: "spo2", 0x02: "resting_heart_rate"}


def parse_minute(timestamp: int, data: bytes) -> MinuteSample:
    """A feature bitmap, an optional second bitmap (when bit 0x80 is set), then the values."""
    s = MinuteSample(timestamp)
    if not data:
        raise ValueError("minute record without a feature bitmap")
    i = 0
    bm1 = data[i]
    i += 1
    bm2 = 0
    if bm1 & 0x80:
        bm2 = data[i]
        i += 1
    bit = 1
    while bit < 0x80:
        if bm1 & bit:
            width = 1 if bit in _ONE_BYTE_FIELDS else 2
            if i + width > len(data):
                raise ValueError(f"minute record too short for bitmap {bm1:02x}: {data.hex()}")
            value = int.from_bytes(data[i : i + width], "big")
            i += width
            if bit in _BITMAP1:
                setattr(s, _BITMAP1[bit], value)
            else:
                s.unknown[f"b1_{bit:02x}"] = value
        bit <<= 1
    bit = 1
    while bit < 0x100:
        if bm2 & bit:
            if i >= len(data):
                raise ValueError(f"minute record too short for bitmap2 {bm2:02x}: {data.hex()}")
            value = data[i]
            i += 1
            if bit in _BITMAP2:
                setattr(s, _BITMAP2[bit], value)
            else:
                s.unknown[f"b2_{bit:02x}"] = value
        bit <<= 1
    return s


def parse_step_data(t: TLV) -> tuple[int, list[MinuteSample]]:
    """Returns (record number, samples). The record carries a base time and per-minute offsets."""
    c = t.child(0x81)
    number = c.uint(0x02)
    base = c.uint(0x03)
    out = []
    for sub in c.children(0x84):
        offset = sub.byte(0x05)
        try:
            out.append(parse_minute(base + 60 * offset, sub.get(0x06, b"")))
        except ValueError as e:
            log.warning("skipping minute at %d: %s", base + 60 * offset, e)
    return number, out


SLEEP_LIGHT = 0x06
SLEEP_DEEP = 0x07
SLEEP_KINDS = {SLEEP_LIGHT: "light", SLEEP_DEEP: "deep"}


@dataclass
class SleepSpan:
    start: int
    end: int
    kind: str
    raw_type: int


def parse_sleep_data(t: TLV) -> tuple[int, list[SleepSpan]]:
    c = t.child(0x81)
    number = c.uint(0x02)
    out = []
    for sub in c.children(0x83):
        kind = sub.byte(0x04)
        ts = sub.get(0x05)
        start = int.from_bytes(ts[0:4], "big")
        minutes = int.from_bytes(ts[4:6], "big")
        out.append(SleepSpan(start, start + minutes * 60, SLEEP_KINDS.get(kind, f"type_{kind}"), kind))
    return number, out
