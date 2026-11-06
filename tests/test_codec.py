import datetime as dt

import pytest

from openband import commands as cmd
from openband import frame
from openband.tlv import TLV, MissingTag, TLVError


def test_tlv_roundtrip_and_nesting():
    inner = TLV().put(0x02, 7, size=2)
    t = TLV().put(0x01).put(0x81, inner).put(0x05, b"x" * 300)
    parsed = TLV.parse(t.serialize())
    assert parsed.get(0x01) == b""
    assert parsed.child(0x81).uint(0x02) == 7
    assert len(parsed.get(0x05)) == 300


def test_tlv_missing_and_truncated():
    with pytest.raises(MissingTag):
        TLV().get(0x09)
    with pytest.raises(TLVError):
        TLV.parse(bytes([0x01, 0x05, 0x00]))


def test_tlv_ignores_trailing_zero():
    assert TLV.parse(bytes([0x01, 0x01, 0x07, 0x00])).byte(0x01) == 7


def test_reassembler_handles_split_and_glued_notifications():
    a = frame.encode(1, 8, TLV().put(0x01, 55, size=1).serialize())
    b = frame.encode(7, 11, bytes(range(256)) * 2, slice_size=60)
    stream = b"".join(a + b)
    r = frame.Reassembler()
    got = []
    for i in range(0, len(stream), 7):
        got += r.feed(stream[i : i + 7])
    assert [(m.service, m.command) for m in got] == [(1, 8), (7, 11)]
    assert got[1].body == bytes(range(256)) * 2


def test_reassembler_rejects_bad_crc():
    p = bytearray(frame.encode(1, 1, b"\x01\x00")[0])
    p[-1] ^= 0xFF
    with pytest.raises(frame.FrameError):
        frame.Reassembler().feed(bytes(p))


def test_minute_record_all_fields():
    # bitmap1 0xCE: steps, calories, distance, heart rate + second bitmap; bitmap2 0x03: SpO2, resting HR
    data = bytes([0xCE, 0x03, 0x00, 0x2A, 0x00, 0x05, 0x00, 0x20, 0x48, 0x61, 0x3C])
    m = cmd.parse_minute(1000, data)
    assert (m.steps, m.calories, m.distance_m, m.heart_rate, m.spo2, m.resting_heart_rate) == (42, 5, 32, 72, 97, 60)
    assert m.unknown == {}


def test_minute_record_unknown_fields_kept():
    m = cmd.parse_minute(0, bytes([0x21, 0x12, 0x34, 0x09]))
    assert m.unknown == {"b1_01": 0x1234, "b1_20": 9}
    assert m.steps is None


def test_minute_record_too_short():
    with pytest.raises(ValueError):
        cmd.parse_minute(0, bytes([0x02, 0x01]))


def test_step_and_sleep_records():
    step = TLV().put(0x81, TLV()
        .put(0x02, 3, size=2)
        .put(0x03, 1_700_000_000, size=4)
        .put(0x84, TLV().put(0x05, 0, size=1).put(0x06, bytes([0x02, 0x00, 0x10])))
        .put(0x84, TLV().put(0x05, 2, size=1).put(0x06, bytes([0x40, 0x50]))))
    number, minutes = cmd.parse_step_data(step)
    assert number == 3
    assert [(m.timestamp, m.steps, m.heart_rate) for m in minutes] == [(1_700_000_000, 16, None), (1_700_000_120, None, 80)]

    ts = (1_700_000_000).to_bytes(4, "big") + (90).to_bytes(2, "big")
    sleep = TLV().put(0x81, TLV().put(0x02, 0, size=2).put(0x83, TLV().put(0x04, 7, size=1).put(0x05, ts)))
    _, spans = cmd.parse_sleep_data(sleep)
    assert spans[0].kind == "deep" and spans[0].end - spans[0].start == 5400


@pytest.mark.parametrize(
    "offset_min, packed",
    [(180, 0x0300), (0, 0x0000), (-300, 0x8500), (330, 0x051E), (-210, (0x83 << 8) | 0xE2)],
)
def test_time_zone_packing(offset_min, packed):
    now = dt.datetime(2026, 11, 6, 12, 0, tzinfo=dt.timezone(dt.timedelta(minutes=offset_min)))
    assert cmd.time_and_zone(now) == (int(now.timestamp()), packed)


def test_security_negotiation_answers():
    assert cmd.parse_security_negotiation(TLV().put(0x02, 2, size=1)) == 2
    assert cmd.parse_security_negotiation(TLV().put(0x01, 1, size=1)) == cmd.HICHAIN_FULL
    assert cmd.is_hichain3(cmd.parse_security_negotiation(TLV().put(0x01, 4, size=1).put(0x02, 1, size=1)))
