"""What the band can do, and telling it what we can do.

The phone announces the services (01/02) and, per service, the commands (01/03) it supports;
the band answers which of them it supports too. Gadgetbridge sends this on every connect, and a
band may only enable a feature (its music screen, for one) once the phone has claimed it. The
expand-capability bitmap (01/37) flags the rest: notification replies, repeated notify, ...

Command lists are Gadgetbridge's (DeviceConfig.SupportedCommands.commandsPerService).
"""

from __future__ import annotations

from .commands import DEVICE_CONFIG, KNOWN_SERVICES, Request
from .tlv import TLV

SUPPORTED_COMMANDS = 0x03
EXPAND_CAPABILITY = 0x37

COMMANDS_PER_SERVICE: dict[int, bytes] = {
    0x01: bytes([0x04, 0x07, 0x08, 0x09, 0x0A, 0x0D, 0x0E, 0x10, 0x11, 0x12, 0x13, 0x14, 0x1B, 0x1A, 0x1D, 0x21,
                 0x22, 0x23, 0x24, 0x29, 0x2A, 0x2B, 0x32, 0x2E, 0x31, 0x30, 0x35, 0x36, 0x37, 0x2F]),
    0x02: bytes([0x01, 0x04, 0x05, 0x06, 0x07, 0x08]),
    0x03: bytes([0x01, 0x03, 0x04]),
    0x04: bytes([0x01]), 0x05: bytes([0x01]), 0x06: bytes([0x01]),
    0x07: bytes([0x01, 0x03, 0x05, 0x07, 0x08, 0x09, 0x0A, 0x0E, 0x10, 0x13, 0x16, 0x15, 0x17, 0x18, 0x1B, 0x1C,
                 0x1D, 0x1E, 0x21, 0x22, 0x23, 0x24, 0x25, 0x28, 0x29, 0x06, 0x1F]),
    0x08: bytes([0x01, 0x02, 0x03]),
    0x09: bytes([0x01, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F]),
    0x0A: bytes([0x01, 0x09, 0x0A]),
    0x0B: bytes([0x01, 0x03]),
    0x0C: bytes([0x01]), 0x0D: bytes([0x01]),
    0x0F: bytes([0x01, 0x03, 0x05, 0x06, 0x07, 0x08, 0x0A, 0x0B, 0x0C]),
    0x10: bytes([0x01]), 0x11: bytes([0x01]), 0x12: bytes([0x01]), 0x13: bytes([0x01]), 0x14: bytes([0x01]),
    0x15: bytes([0x01]),
    0x16: bytes([0x01, 0x03, 0x07]),
    0x17: bytes([0x01, 0x04, 0x06, 0x07, 0x0B, 0x0C, 0x10, 0x12, 0x15, 0x17]),
    0x18: bytes([0x01, 0x02, 0x04, 0x05, 0x06, 0x09]),
    0x19: bytes([0x01, 0x04]),
    0x1A: bytes([0x01, 0x03, 0x07, 0x05, 0x06]),
    0x1B: bytes([0x01, 0x0F, 0x19, 0x1A]),
    0x1D: bytes(range(0x01, 0x0B)),
    0x20: bytes([0x01, 0x02, 0x03, 0x04, 0x09, 0x0A]),
    0x22: bytes([0x01]),
    0x23: bytes([0x02, 0x0B]),
    0x24: bytes(range(0x01, 0x0D)),
    0x25: bytes([0x02, 0x04, 0x0E]),
    0x26: bytes([0x02, 0x03]),
    0x27: bytes([0x01, 0x0E]),
    0x2A: bytes([0x01, 0x06]),
    0x2B: bytes([0x12]),
    0x2D: bytes([0x01]),
    0x2E: bytes([0x01, 0x02, 0x03]),
    0x30: bytes([0x01]), 0x32: bytes([0x01]),
    0x33: bytes([0x01, 0x02]),
    0x34: bytes([0x01]),
    0x35: bytes([0x03, 0x04]),
}

SERVICE_NAMES = {
    0x01: "device config", 0x02: "notifications", 0x03: "contacts", 0x04: "calls", 0x05: "messages?",
    0x07: "fitness", 0x08: "alarms", 0x09: "OTA", 0x0A: "maintenance", 0x0B: "find phone", 0x0C: "factory",
    0x0D: "weather?", 0x0F: "workout?", 0x16: "workout", 0x18: "GPS", 0x1A: "file upload?", 0x1B: "weather?",
    0x20: "", 0x23: "earphones?", 0x24: "", 0x25: "music", 0x27: "watchface?", 0x2A: "", 0x2B: "",
}

# Expand-capability bits Gadgetbridge reads (HuaweiState).
CAPABILITY_NAMES = {
    0x1D: "?", 0x2F: "?", 0x38: "dual socket", 0x3B: "?", 73: "notification reply actions",
    77: "notification icon/timestamp", 89: "notification reply", 94: "repeated notify", 120: "remove single notification",
    0x9A: "?", 0x9C: "?", 142: "extend socket",
}


def supported_services() -> Request:
    return Request(DEVICE_CONFIG, 0x02, TLV().put(0x01, KNOWN_SERVICES))


def services_from(t: TLV) -> list[int]:
    flags = t.get(0x02, b"")
    return [0x01] + [s for s, on in zip(KNOWN_SERVICES, flags, strict=False) if on]


def supported_commands(services: list[int], slice_size: int = 0xF4) -> list[Request]:
    """One or more requests (they are split to fit an encrypted slice, as Gadgetbridge does)."""
    limit = slice_size - 32
    limit = limit - (limit % 16) - 4
    out: list[Request] = []
    inner = TLV()
    size = 0
    for s in services:
        cmds = COMMANDS_PER_SERVICE.get(s)
        if not cmds:
            continue
        if size + len(cmds) + 5 > limit and size:
            out.append(Request(DEVICE_CONFIG, SUPPORTED_COMMANDS, TLV().put(0x81, inner)))
            inner, size = TLV(), 0
        inner.put(0x02, s, size=1).put(0x03, cmds)
        size += len(cmds) + 5
    if size:
        out.append(Request(DEVICE_CONFIG, SUPPORTED_COMMANDS, TLV().put(0x81, inner)))
    return out


def commands_from(t: TLV) -> dict[int, list[int]]:
    """The band's answer: per service, the commands it supports too."""
    result: dict[int, list[int]] = {}
    service = None
    for tag, value in TLV.parse(t.get(0x81, b"")):
        if tag == 0x02:
            service = value[0]
        elif tag == 0x04 and service is not None:
            known = COMMANDS_PER_SERVICE.get(service, b"")
            result[service] = [known[i] for i, on in enumerate(value) if on == 1 and i < len(known)]
    return result


def expand_capability() -> Request:
    return Request(DEVICE_CONFIG, EXPAND_CAPABILITY, TLV().put(0x01))


def capability_bits(raw: bytes) -> list[int]:
    return [i for i in range(len(raw) * 8) if raw[i // 8] & (1 << (i % 8))]


# --- presenting as a phone ------------------------------------------------------------------------
# What Gadgetbridge tells a band about the phone (DeviceConfig.PhoneInfo, 01/10): an Android phone with
# Huawei Health 16.1.3.320. Some features (the music screen on a Band 6, per Huawei's manual) are said to
# exist only with Android phones; a band set up from an iPhone may have them off. Experimental.

PHONE_INFO = 0x10
CONNECT_STATUS = 0x35
DEFAULT_SWITCH = 0x21


def phone_info(tags: bytes = bytes([0x02, 0x04, 0x08, 0x10, 0x11, 0x13, 0x14, 0x15, 0x16])) -> Request:
    t = TLV()
    for tag in tags:
        if tag in (0x02, 0x04, 0x15):
            t.put(tag)  # manufacturer, model, OS platform version: empty, as Gadgetbridge
        elif tag == 0x08:
            t.put(tag, "14")  # Android version
        elif tag == 0x11:
            t.put(tag, 1600103320, size=4)  # app version 16.1.3.320
        elif tag == 0x0F:
            continue
        else:
            t.put(tag, 0, size=1)
    return Request(DEVICE_CONFIG, PHONE_INFO, t)


def connect_status() -> Request:
    return Request(DEVICE_CONFIG, CONNECT_STATUS, TLV().put(0x01, 1, size=1))


def default_switch() -> Request:
    return Request(DEVICE_CONFIG, DEFAULT_SWITCH, TLV().put(0x01))
