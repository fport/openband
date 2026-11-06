"""End to end against the simulated band: every auth path, then encrypted requests and a sync."""

import pytest

from openband import commands as cmd
from openband.auth import AuthError, NeedsBond, authenticate
from openband.link import Band, BandRefused
from openband.store import BandRecord, Store
from openband.sync import fetch_history
from openband.tlv import TLV

from fake_band import BandConfig, FakeBand

PATHS = {
    "normal-v2": BandConfig(support_type=0, auth_version=2),
    "normal-v1-gcm": BandConfig(support_type=0, auth_version=1, encrypt_method=1),
    "hichain-lite-pin": BandConfig(support_type=2, auth_version=3),
    "hichain-lite-pin-pbkdf2": BandConfig(support_type=2, auth_version=3, auth_algo=1),
    "hichain-lite-v2-key": BandConfig(support_type=2, auth_version=2),
    "hichain-lite-gcm": BandConfig(support_type=1, auth_version=3, encrypt_method=1, negotiated_auth_type=1),
    "bond-unanswered": BandConfig(support_type=2, auth_version=3, answer_bond=False),
}


def record(cfg: BandConfig) -> BandRecord:
    rec = BandRecord.new("TEST-ADDR", "HUAWEI Band 6-ABC")
    rec.band_mac = cfg.mac
    return rec


@pytest.mark.parametrize("name", PATHS)
async def test_pair_then_encrypted_requests(name):
    cfg = PATHS[name]
    rec = record(cfg)
    fake = FakeBand(cfg, client_key=rec.key)
    band = Band(fake, timeout=1 if not cfg.answer_bond else 2)
    report = await authenticate(band, rec, allow_bond=True)
    assert report.bonded_now
    assert fake.session_key == rec.key
    assert cmd.parse_battery(await band.request(cmd.battery())) == 77
    info = cmd.parse_product_info(await band.request(cmd.product_info()))
    assert (info.model, info.software_version) == ("FRA-B19", "1.0.1.36")
    await band.request(cmd.set_time())
    totals = cmd.parse_fitness_totals(await band.request(cmd.fitness_totals()))
    assert (totals.steps, totals.calories, totals.distance_m) == (1234, 56, 900)


async def test_refuses_to_bond_without_permission():
    cfg = BandConfig()
    rec = record(cfg)
    with pytest.raises(NeedsBond):
        await authenticate(Band(FakeBand(cfg)), rec, allow_bond=False)


async def test_normal_mode_needs_band_mac():
    cfg = BandConfig(support_type=0, auth_version=2)
    rec = record(cfg)
    rec.band_mac = ""
    with pytest.raises(NeedsBond, match="MAC"):
        await authenticate(Band(FakeBand(cfg)), rec, allow_bond=True)


async def test_full_hichain_is_reported():
    cfg = BandConfig(support_type=1, negotiated_auth_type=0)
    fake = FakeBand(cfg)
    fake.handle_orig = fake.handle

    def handle(sid, cid, t):
        if (sid, cid) == (1, cmd.SECURITY_NEGOTIATION):
            return False, TLV().put(0x01, 1, size=1)
        return fake.handle_orig(sid, cid, t)

    fake.handle = handle
    with pytest.raises(AuthError, match="full HiChain"):
        await authenticate(Band(fake), record(cfg), allow_bond=True)


async def test_wrong_pin_fails_the_challenge():
    cfg = BandConfig()
    fake = FakeBand(cfg)
    fake.cfg = BandConfig(pin=b"000000")  # band checks against a different PIN than it hands out
    orig = fake.handle

    def handle(sid, cid, t):
        if (sid, cid) == (1, cmd.PIN_CODE):
            fake.cfg = BandConfig(pin=b"482913")
            out = orig(sid, cid, t)
            fake.cfg = BandConfig(pin=b"000000")
            return out
        return orig(sid, cid, t)

    fake.handle = handle
    with pytest.raises(BandRefused):
        await authenticate(Band(fake), record(cfg), allow_bond=True)


async def test_reconnect_after_pairing_uses_stored_record(tmp_path):
    cfg = BandConfig(support_type=0, auth_version=2, bond_status=1)
    store = Store(tmp_path / "bands.json")
    rec = record(cfg)
    rec.bonded = True
    store.save(rec)
    again = store.get("TEST-ADDR")
    fake = FakeBand(cfg, session_key=again.key)
    band = Band(fake)
    report = await authenticate(band, again, allow_bond=False)
    assert not report.bonded_now
    assert (1, cmd.BOND) not in fake.seen  # normal mode, band says bonded: skip
    assert cmd.parse_battery(await band.request(cmd.battery())) == 77
    assert oct((tmp_path / "bands.json").stat().st_mode & 0o777) == "0o600"


async def test_sync_pulls_minutes_and_skips_missing_sleep():
    cfg = BandConfig()
    rec = record(cfg)
    fake = FakeBand(cfg)
    base = 1_762_400_000
    for n in range(2):
        minutes = TLV().put(0x02, n, size=2).put(0x03, base + n * 3600, size=4)
        for off in range(3):
            minutes.put(0x84, TLV().put(0x05, off, size=1).put(0x06, bytes([0xC2, 0x01, 0x00, 10 + off, 70 + off, 98])))
        fake.steps_records.append(TLV().put(0x81, minutes))
    band = Band(fake)
    await authenticate(band, rec, allow_bond=True)
    h = await fetch_history(band, base - 60, base + 7200)
    assert len(h.minutes) == 6
    assert h.minutes[0].steps == 10 and h.minutes[0].heart_rate == 70 and h.minutes[0].spo2 == 98
    assert h.minutes[-1].timestamp == base + 3600 + 120
    assert h.sleep == []
