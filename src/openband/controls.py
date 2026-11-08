"""Things you do with the band rather than read from it: notifications and its music buttons.

Notifications (service 0x02, command 0x01): a title, a sender and a text, shown and vibrated on
the band. Anything on the computer can send one, for example a Claude Code hook.

Find phone (service 0x0B): tapping "Find phone" on the band sends 0B/01 with tag 01 = 1 (start)
or 0 (stop). On bands without a music screen this is the one button we get; `openband listen`
answers every start with 0B/02 (stop), so the band is ready for the next tap at once.

Music control (service 0x25): the band's music screen sends a button press as 25/03 with tag 01
(1 play, 2 pause, 3 previous, 4 next, 5 volume up, 6 volume down) and expects an acknowledgement.
It asks for what is playing with 25/01; we answer with 25/02 (artist, title, state, volume), which
is a handy one-line display: `openband listen` uses it to show what a button did.
"""

from __future__ import annotations

from dataclasses import dataclass

from .commands import Request
from .session import RESULT_SUCCESS, TAG_RESULT
from .tlv import TLV

NOTIFICATIONS = 0x02
NOTIFICATION_SEND = 0x01

TYPE_GENERIC = 0x7F
TEXT_TEXT = 0x01
TEXT_SENDER = 0x02
TEXT_TITLE = 0x03
# Content format from the band's notification constraints; 2 is Gadgetbridge's default.
ENCODING_UTF8 = 0x02
MAX_TEXT = 300

MUSIC = 0x25
MUSIC_STATUS = 0x01
MUSIC_INFO = 0x02
MUSIC_CONTROL = 0x03

FIND_PHONE = 0x0B
FIND_PHONE_EVENT = 0x01
FIND_PHONE_STOP = 0x02

# Android's PlaybackState values, which the band expects (Gadgetbridge SetMusicRequest): 0 none, 1 stopped,
# 2 paused, 3 playing. Anything but "playing" makes the band say it cannot control music.
PAUSED = 2
PLAYING = 3

BUTTONS = {1: "play", 2: "pause", 3: "previous", 4: "next", 5: "volume_up", 6: "volume_down"}


def _clip(text: str, limit: int = MAX_TEXT) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def notification(msg_id: int, title: str, text: str, sender: str = "Openband") -> Request:
    items = TLV()
    for kind, value in ((TEXT_TITLE, title), (TEXT_SENDER, sender), (TEXT_TEXT, text)):
        el = TLV().put(0x0E, kind, size=1).put(0x0F, ENCODING_UTF8, size=1)
        if value:
            el.put(0x10, _clip(value))
        items.put(0x8D, el)
    t = (
        TLV()
        .put(0x01, msg_id & 0xFFFF, size=2)
        .put(0x02, TYPE_GENERIC, size=1)
        .put(0x03, True)
        .put(0x84, TLV().put(0x8C, items))
        .put(0x11, "dev.openband")
    )
    return Request(NOTIFICATIONS, NOTIFICATION_SEND, t)


def music_ack(command: int) -> Request:
    return Request(MUSIC, command, TLV().put(TAG_RESULT, RESULT_SUCCESS, size=4), expects_reply=False)


def music_info(artist: str, title: str, playing: bool = True, max_volume: int = 10, volume: int = 5) -> Request:
    t = (
        TLV()
        .put(0x01, _clip(artist, 60))
        .put(0x02, _clip(title, 60))
        .put(0x03, PLAYING if playing else PAUSED, size=1)
        .put(0x04, max_volume, size=1)
        .put(0x05, volume, size=1)
    )
    return Request(MUSIC, MUSIC_INFO, t)


@dataclass
class ButtonPress:
    code: int
    name: str
    volume: int | None = None


def parse_button(t: TLV) -> ButtonPress | None:
    """A 25/03 from the band, or None when it carries neither a button nor a volume."""
    raw = t.get(0x01, b"")
    volume = t.get(0x02, b"")
    vol = volume[-1] if volume else None
    if raw:
        code = raw[-1]
        return ButtonPress(code, BUTTONS.get(code, f"button_{code}"), vol)
    if vol is not None:
        return ButtonPress(0, "volume", vol)
    return None


def find_phone_started(t: TLV) -> bool:
    raw = t.get(0x01, b"")
    return bool(raw) and raw[-1] == 1


def find_phone_stop() -> Request:
    return Request(FIND_PHONE, FIND_PHONE_STOP, TLV().put(0x01, 2, size=1), expects_reply=False)
