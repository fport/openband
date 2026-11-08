"""openband: talk to a Huawei Band 6 from your computer.

  openband scan              list Huawei bands nearby
  openband probe             read the band's link parameters (changes nothing)
  openband pair              pair Openband with the band (writes a new key to it)
  openband status            battery, today's totals, firmware
  openband sync --days 7     per-minute activity, heart rate and sleep, as JSON or CSV
  openband set-time          set the band's clock from this computer
  openband forget            drop what Openband remembers about a band
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import datetime as dt
import json
import logging
import sys
import time
from dataclasses import asdict
from pathlib import Path

from . import __version__
from . import commands as cmd
from .auth import AuthError, authenticate, describe, read_link_params
from .link import SERVICE_UUID, Band, BandError, Connection, find_band
from .store import BandRecord, Store
from .sync import fetch_history

PAIR_WARNING = """\
Pairing writes a new key to the band. After this:
  - Huawei Health on your phone loses the band and has to pair again to use it.
  - Keep Bluetooth off on that phone (or Huawei Health closed) while Openband talks to the band.
Nothing is deleted from the band, and you can go back to Huawei Health any time by pairing there.
"""


def out(msg: str = "") -> None:
    print(msg, flush=True)


async def _target(args, store: Store):
    """Find the band: explicit address, then the one band we know, then a scan."""
    address = args.address
    if not address and not args.name:
        known = store.all()
        if len(known) == 1:
            address = known[0].address
    wait = getattr(args, "wait", 90.0)
    out(f"Looking for the band (up to {wait:.0f}s). If it does not show up, wake its screen or restart it")
    out("(Settings > System > Restart on the band); Openband connects as soon as it appears.")
    dev = await find_band(name_hint=args.name, address=address, timeout=wait)
    return dev


async def _session(args, store: Store):
    dev = await _target(args, store)
    rec = store.get_or_create(dev.address, dev.name or "")
    if getattr(args, "band_mac", None):
        rec.band_mac = args.band_mac.upper()
    return dev, rec


# --- commands -------------------------------------------------------------------------------


async def do_scan(args, store: Store) -> int:
    from bleak import BleakScanner

    out(f"Scanning for {args.timeout:.0f}s ...")
    found = await BleakScanner.discover(timeout=args.timeout, return_adv=True)
    rows = []
    for dev, adv in found.values():
        name = dev.name or adv.local_name or ""
        huawei = SERVICE_UUID in [u.lower() for u in adv.service_uuids] or name.lower().startswith(("huawei", "honor"))
        if huawei or args.all:
            rows.append((adv.rssi, dev.address, name or "(no name)", "huawei" if huawei else ""))
    if not rows:
        out("No Huawei band found. Turn Bluetooth off on the phone the band is paired with, then try again.")
        return 1
    for rssi, address, name, tag in sorted(rows, reverse=True):
        out(f"{rssi:>4} dBm  {address}  {name}  {tag}")
    return 0


async def do_probe(args, store: Store) -> int:
    dev = await _target(args, store)
    out(f"Connecting to {dev.name or dev.address} ...")
    async with Connection(dev, connect_timeout=getattr(args, "wait", 90.0)) as band:
        params = await read_link_params(band)
    info = {"name": dev.name, "address": dev.address, **describe(params)}
    out(json.dumps(info, indent=2))
    path = "HiChain Lite or full HiChain (decided in the next step)" if params.uses_hichain else "normal mode (needs the band's MAC to bond)"
    out(f"\nAuth path: {path}.")
    return 0


async def _after_auth(band: Band) -> dict:
    info = cmd.parse_product_info(await band.request(cmd.product_info()))
    level = cmd.parse_battery(await band.request(cmd.battery()))
    return {"product": asdict(info), "battery": level}


async def do_pair(args, store: Store) -> int:
    known = store.get(args.address) if args.address else None
    if known and known.bonded and not args.again:
        out("Openband is already paired with this band. Use `openband status`, or `pair --again` to redo it.")
        return 0
    # Ask before looking for the band: it may only advertise for a short while.
    out(PAIR_WARNING)
    if not args.yes:
        answer = input("Pair now? [y/N] ").strip().lower()
        if answer not in ("y", "yes", "e", "evet"):
            out("Nothing changed.")
            return 1
    dev, rec = await _session(args, store)
    if rec.bonded and not args.again:
        out("Openband is already paired with this band. Use `openband status`, or `pair --again` to redo it.")
        return 0
    if args.again:
        rec.bonded = False
    out(f"Connecting to {dev.name or dev.address} ...")
    async with Connection(dev, connect_timeout=getattr(args, "wait", 90.0)) as band:
        report = await authenticate(band, rec, allow_bond=True)
        rec.bonded = True
        rec.name = dev.name or rec.name
        store.save(rec)
        out(f"Authenticated ({'HiChain Lite' if report.auth_mode == 2 else 'normal mode'}), key handed to the band.")
        try:
            details = await _after_auth(band)
        except BandError as e:
            out(f"Paired, but the first encrypted request failed: {e}")
            out("Run `openband -v status` and share the log; the bond may not have taken.")
            return 2
        await band.request(cmd.set_time())
    p = details["product"]
    out(f"Paired with {p['model'] or dev.name}, firmware {p['software_version']}, battery {details['battery']}%.")
    out("Clock set from this computer.")
    return 0


async def _connect_authed(args, store: Store):
    dev, rec = await _session(args, store)
    if not rec.bonded:
        raise AuthError("Openband has not been paired with this band yet; run `openband pair` first")
    conn = Connection(dev, connect_timeout=getattr(args, "wait", 90.0))
    band = await conn.__aenter__()
    try:
        await authenticate(band, rec, allow_bond=False)
    except BaseException:
        await conn.__aexit__(None, None, None)
        raise
    return conn, band, rec


async def do_status(args, store: Store) -> int:
    conn, band, rec = await _connect_authed(args, store)
    try:
        details = await _after_auth(band)
        totals = cmd.parse_fitness_totals(await band.request(cmd.fitness_totals()))
    finally:
        await conn.__aexit__(None, None, None)
    p = details["product"]
    if args.json:
        out(json.dumps({**details, "today": asdict(totals)}, indent=2))
        return 0
    out(f"{p['model'] or rec.name}  firmware {p['software_version']}")
    out(f"Battery   {details['battery']}%")
    out(f"Today     {totals.steps} steps, {totals.calories} kcal, {totals.distance_m} m")
    return 0


async def do_set_time(args, store: Store) -> int:
    conn, band, _ = await _connect_authed(args, store)
    try:
        await band.request(cmd.set_time())
    finally:
        await conn.__aexit__(None, None, None)
    out("Clock set.")
    return 0


def _iso(ts: int) -> str:
    return dt.datetime.fromtimestamp(ts).astimezone().isoformat(timespec="minutes")


async def do_sync(args, store: Store) -> int:
    end = int(time.time())
    start = end - int(args.days * 86400)
    conn, band, rec = await _connect_authed(args, store)
    try:
        def progress(kind, n):
            print(f"\r{kind}: {n}   ", end="", file=sys.stderr, flush=True)

        h = await fetch_history(band, start, end, progress)
        print(file=sys.stderr)
    finally:
        await conn.__aexit__(None, None, None)

    outdir = Path(args.out)
    outdir.mkdir(parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M")
    if args.format == "json":
        path = outdir / f"openband-{stamp}.json"
        path.write_text(json.dumps({
            "band": rec.name,
            "from": _iso(start),
            "to": _iso(end),
            "minutes": [{"time": _iso(m.timestamp), **asdict(m)} for m in h.minutes],
            "sleep": [{"from": _iso(s.start), "to": _iso(s.end), **asdict(s)} for s in h.sleep],
        }, indent=1))
        out(f"Wrote {path}")
    else:
        mpath = outdir / f"openband-{stamp}-minutes.csv"
        with mpath.open("w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["time", "steps", "calories", "distance_m", "heart_rate", "spo2", "resting_heart_rate"])
            for m in h.minutes:
                w.writerow([_iso(m.timestamp), m.steps, m.calories, m.distance_m, m.heart_rate, m.spo2, m.resting_heart_rate])
        spath = outdir / f"openband-{stamp}-sleep.csv"
        with spath.open("w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["from", "to", "kind"])
            for s in h.sleep:
                w.writerow([_iso(s.start), _iso(s.end), s.kind])
        out(f"Wrote {mpath} and {spath}")
    hr = [m.heart_rate for m in h.minutes if m.heart_rate]
    steps = sum(m.steps or 0 for m in h.minutes)
    sleep_min = sum(s.end - s.start for s in h.sleep) // 60
    out(f"{len(h.minutes)} minutes, {steps} steps, {len(hr)} heart rate readings, {sleep_min // 60}h{sleep_min % 60:02d} of sleep.")
    return 0


async def do_forget(args, store: Store) -> int:
    known = {r.address: r for r in store.all()}
    target = args.address or (next(iter(known)) if len(known) == 1 else None)
    if not target or target not in known:
        out("Which band? Pass --address (see `openband scan`).")
        return 1
    store.remove(target)
    out(f"Forgot {known[target].name or target}. The band keeps our old key until it pairs again.")
    return 0


# --- entry point ----------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="openband", description="Read your Huawei Band 6 without Huawei Health.")
    p.add_argument("--version", action="version", version=f"openband {__version__}")
    p.add_argument("-v", "--verbose", action="count", default=0, help="-v: steps, -vv: every byte on the wire")
    p.add_argument("--address", help="the band's Bluetooth address (a UUID on macOS); see `openband scan`")
    p.add_argument("--name", help="pick the band whose name contains this")
    p.add_argument("--wait", type=float, default=90.0, help="seconds to wait for the band to show up (default 90)")
    sub = p.add_subparsers(dest="command", required=True)

    s = sub.add_parser("scan", help="list Huawei bands nearby")
    s.add_argument("--timeout", type=float, default=8.0)
    s.add_argument("--all", action="store_true", help="list every Bluetooth LE device")

    sub.add_parser("probe", help="read link parameters; changes nothing on the band")

    s = sub.add_parser("pair", help="pair Openband with the band")
    s.add_argument("--band-mac", help="the band's Bluetooth MAC (Settings > About on the band); normal mode needs it")
    s.add_argument("--yes", action="store_true", help="do not ask")
    s.add_argument("--again", action="store_true", help="pair again even if Openband already did")

    s = sub.add_parser("status", help="battery, today's totals, firmware")
    s.add_argument("--json", action="store_true")

    sub.add_parser("set-time", help="set the band's clock")

    s = sub.add_parser("sync", help="download activity, heart rate and sleep")
    s.add_argument("--days", type=float, default=7)
    s.add_argument("--out", default=".")
    s.add_argument("--format", choices=("json", "csv"), default="json")

    sub.add_parser("forget", help="drop what Openband remembers about a band")
    return p


COMMANDS = {
    "scan": do_scan,
    "probe": do_probe,
    "pair": do_pair,
    "status": do_status,
    "set-time": do_set_time,
    "sync": do_sync,
    "forget": do_forget,
}


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    level = logging.WARNING if args.verbose == 0 else logging.INFO if args.verbose == 1 else logging.DEBUG
    logging.basicConfig(level=level, format="%(asctime)s %(name)s %(message)s", datefmt="%H:%M:%S")
    if args.verbose < 2:
        logging.getLogger("bleak").setLevel(logging.WARNING)
    try:
        return asyncio.run(COMMANDS[args.command](args, Store()))
    except KeyboardInterrupt:
        return 130
    except BandError as e:
        out(f"error: {e}")
        return 2


if __name__ == "__main__":
    sys.exit(main())
