"""openband: talk to a Huawei Band 6 from your computer.

  openband scan              list Huawei bands nearby
  openband probe             read the band's link parameters (changes nothing)
  openband pair              pair Openband with the band (writes a new key to it)
  openband status            battery, today's totals, firmware
  openband sync --days 7     per-minute activity, heart rate and sleep, as JSON or CSV
  openband set-time          set the band's clock from this computer
  openband forget            drop what Openband remembers about a band
  openband key               print the pairing key for the iPhone app
  openband notify TITLE TEXT show a notification on the band
  openband listen            react to the band's music buttons (--exec runs a command per press)
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import datetime as dt
import json
import logging
import os
import sys
import time
from dataclasses import asdict
from pathlib import Path

from . import __version__
from . import commands as cmd
from . import controls
from .auth import AuthError, authenticate, describe, read_link_params
from .link import SERVICE_UUID, Band, BandError, Connection, find_band
from .store import BandRecord, Store
from .sync import fetch_history

log = logging.getLogger("openband")

PAIR_WARNING = """\
Pairing writes a new key to the band. After this:
  - Huawei Health on your phone loses the band and has to pair again to use it.
  - Keep Bluetooth off on that phone (or Huawei Health closed) while Openband talks to the band.
Nothing is deleted from the band, and you can go back to Huawei Health any time by pairing there.
"""


def out(msg: str = "") -> None:
    try:
        print(msg, flush=True)
    except BrokenPipeError:
        # Whoever read our output (so101-band, a pipe) is gone: a listener left behind would hold the
        # band and its socket, so leave at once.
        os._exit(0)


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


def socket_path() -> Path:
    from .store import home

    return home() / "listen.sock"


async def _notify_via_listener(payload: dict) -> str | None:
    """Hand the notification to a running `openband listen`; None when none is running."""
    path = socket_path()
    if not path.exists():
        return None
    try:
        reader, writer = await asyncio.open_unix_connection(str(path))
    except (ConnectionRefusedError, FileNotFoundError, OSError):
        return None
    writer.write((json.dumps(payload) + "\n").encode())
    await writer.drain()
    answer = (await asyncio.wait_for(reader.readline(), 30.0)).decode().strip()
    writer.close()
    return answer or "error: no answer"


async def do_notify(args, store: Store) -> int:
    payload = {"title": args.title, "text": args.text or "", "sender": args.sender}
    if args.music:
        payload = {"music": " ".join(t for t in (args.title, args.text) if t)}
    answer = await _notify_via_listener(payload)
    if answer is None and args.music:
        out("error: --music needs a running `openband listen`")
        return 2
    if answer is not None:
        if answer != "ok":
            out(answer)
            return 2
        out("Sent.")
        return 0
    if args.no_bluetooth:
        out("error: `openband listen` is not running")
        return 2
    conn, band, _ = await _connect_authed(args, store)
    try:
        await _notify(band, payload)
    finally:
        await conn.__aexit__(None, None, None)
    out("Sent.")
    return 0


async def _notify(band: Band, payload: dict) -> None:
    req = controls.notification(int(time.time() * 10) & 0xFFFF, payload.get("title", ""), payload.get("text", ""),
                                payload.get("sender") or "Openband")
    try:
        await band.request(req, timeout=4.0)
    except BandError as e:
        # The band shows the notification whether or not it answers.
        log.info("notification: %s", e)


async def do_listen(args, store: Store) -> int:
    """Stay connected: music-screen presses become lines (and commands), and `openband notify`
    from any shell reaches the band through a local socket, without Bluetooth of its own."""
    loop = asyncio.get_running_loop()
    tasks: set[asyncio.Task] = set()
    # What the band believes the player is doing. It only sends the next play/pause press once the
    # phone has confirmed the last one (as a real player would), so every screen update echoes it.
    player = {"playing": True}
    inbox: asyncio.Queue[tuple[dict, asyncio.Future]] = asyncio.Queue()

    async def on_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            payload = json.loads((await reader.readline()).decode() or "{}")
            done: asyncio.Future = loop.create_future()
            await inbox.put((payload, done))
            answer = await asyncio.wait_for(done, 120.0)
        except Exception as e:  # noqa: BLE001 - report anything back to the caller
            answer = f"error: {e}"
        try:
            writer.write((answer + "\n").encode())
            await writer.drain()
            writer.close()
        except (ConnectionError, OSError):
            pass  # the sender gave up waiting; nothing to tell it

    path = socket_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.unlink(missing_ok=True)
    server = await asyncio.start_unix_server(on_client, path=str(path))
    os.chmod(path, 0o600)

    async def run(press: controls.ButtonPress, band: Band) -> None:
        line = json.dumps({"ts": int(time.time()), "button": press.name, "code": press.code, "volume": press.volume,
                           "t": round(time.time(), 3)})
        out(line)
        label = press.name
        if args.exec:
            env = {**os.environ, "OPENBAND_BUTTON": press.name, "OPENBAND_EVENT": line}
            proc = await asyncio.create_subprocess_shell(args.exec, env=env, stdout=asyncio.subprocess.PIPE)
            stdout, _ = await proc.communicate()
            reply = stdout.decode(errors="replace").strip().splitlines()
            if reply:
                label = reply[-1]
            elif proc.returncode:
                label = f"{press.name}: exit {proc.returncode}"
        if not args.exec:
            return  # whoever reads our output (so101-band) writes the band's screen itself
        if press.name == "find":
            # No music screen to write on: show what the command printed as a notification.
            if label != press.name:
                await _notify(band, {"title": args.title, "text": label, "sender": args.title})
        else:
            await band.send(controls.music_info(args.title, label))

    try:
        while True:
            try:
                conn, band, _ = await _connect_authed(args, store)
            except BandError as e:
                out(f"{e}; trying again (wake the band's screen).")
                await asyncio.sleep(2.0)
                continue
            out("Listening. Tap \"Find phone\" on the band (or use its music screen); "
                "`openband notify` from any shell goes through here. Ctrl+C to stop.")

            def on_message(service: int, command: int, body, band=band) -> None:
                if service == controls.FIND_PHONE and command == controls.FIND_PHONE_EVENT:
                    if not controls.find_phone_started(body):
                        return
                    press = controls.ButtonPress(0, "find")
                    t = loop.create_task(_find_then(band, run(press, band)))
                    tasks.add(t)
                    t.add_done_callback(tasks.discard)
                    return
                if service != controls.MUSIC:
                    return
                if command == controls.MUSIC_STATUS:
                    t = loop.create_task(_send_all(band, controls.music_ack(command), controls.music_info(args.title, "ready")))
                elif command == controls.MUSIC_CONTROL:
                    press = controls.parse_button(body)
                    if press is None:
                        return
                    if press.code in (1, 3, 4):  # play, previous, next: a player plays on
                        player["playing"] = True
                    elif press.code == 2:  # pause
                        player["playing"] = False
                    if press.code not in controls.BUTTONS:
                        # 100 arrives when the band connects or opens its music screen: not a press.
                        t = loop.create_task(_send_all(band, controls.music_ack(command), controls.music_info(args.title, "ready")))
                    else:
                        t = loop.create_task(_ack_then(band, command, run(press, band)))
                else:
                    return
                tasks.add(t)
                t.add_done_callback(tasks.discard)

            band.listen(on_message)

            async def setup(band=band) -> None:
                t0 = time.monotonic()
                try:
                    await asyncio.wait_for(_announce(band), 15.0)
                except asyncio.TimeoutError:
                    log.warning("announce took too long; carrying on")
                # The band asks for the music state (25/01) as soon as it connects, before our key is in
                # place, so that first ask goes unanswered: answer it now.
                await band.send(controls.music_ack(controls.MUSIC_STATUS))
                await band.send(controls.music_info(args.title, "ready"))
                log.info("setup done in %.1f s", time.monotonic() - t0)

            # Runs beside the inbox: a slow answer during setup must not hold up the screen.
            setup_task = loop.create_task(setup())
            try:
                while conn.client is not None and conn.client.is_connected:
                    try:
                        payload, done = await asyncio.wait_for(inbox.get(), 1.0)
                    except asyncio.TimeoutError:
                        continue
                    t0 = time.monotonic()
                    try:
                        if "music" in payload:
                            await asyncio.wait_for(band.send(controls.music_info(
                                args.title, str(payload["music"]), playing=player["playing"])), 5.0)
                            out(f"music screen in {1000 * (time.monotonic() - t0):.0f} ms: {payload['music']}")
                        else:
                            await asyncio.wait_for(_notify(band, payload), 8.0)
                            out(f"notified: {payload.get('title', '')}")
                        if not done.done():
                            done.set_result("ok")
                    except Exception as e:  # noqa: BLE001
                        log.warning("inbox: %r", e)
                        if not done.done():
                            done.set_result(f"error: {e!r}")
            finally:
                setup_task.cancel()
                await conn.__aexit__(None, None, None)
            out("The band disconnected; reconnecting (wake its screen).")
    finally:
        server.close()
        path.unlink(missing_ok=True)


async def _announce(band: Band) -> None:
    """Present as Gadgetbridge does (services, commands, an Android phone). A Band 6 set up from an
    iPhone shows its Music app only after this; then its buttons reach `listen`."""
    from . import capabilities as caps

    try:
        services = caps.services_from(await band.request(caps.supported_services()))
        for req in caps.supported_commands(services, band.session.params.slice_size):
            await band.request(req)
        await band.request(caps.phone_info(), timeout=4.0)
        log.info("announced as an Android phone")
    except BandError as e:
        log.info("announce: %s", e)


async def _send_all(band: Band, *reqs) -> None:
    for r in reqs:
        await band.send(r)


async def _find_then(band: Band, then) -> None:
    # Stop the band's "finding" screen first, so the next tap counts again.
    await band.send(controls.find_phone_stop())
    await then


async def _ack_then(band: Band, command: int, then) -> None:
    await band.send(controls.music_ack(command))
    await then


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


async def do_caps(args, store: Store) -> int:
    """Tell the band what Openband supports and print what it supports back."""
    from . import capabilities as caps

    conn, band, _ = await _connect_authed(args, store)
    try:
        services = caps.services_from(await band.request(caps.supported_services()))
        out(f"Services: {' '.join(f'{s:02x}' for s in services)}")
        for req in caps.supported_commands(services, band.session.params.slice_size):
            for service, cmds in caps.commands_from(await band.request(req)).items():
                name = caps.SERVICE_NAMES.get(service, "")
                out(f"  {service:02x} {name:<14} {' '.join(f'{c:02x}' for c in cmds)}")
        try:
            raw = (await band.request(caps.expand_capability())).get(0x01, b"")
            bits = caps.capability_bits(raw)
            out(f"Expand capabilities ({len(bits)} bits): {' '.join(str(b) for b in bits)}")
            for bit, name in caps.CAPABILITY_NAMES.items():
                if bit in bits and name != "?":
                    out(f"  {bit}: {name}")
        except BandError as e:
            out(f"Expand capabilities: {e}")
    finally:
        await conn.__aexit__(None, None, None)
    out("Now look at the band's app list: a Music app may have appeared.")
    return 0


async def do_announce(args, store: Store) -> int:
    """Experimental: tell the band what Gadgetbridge tells it (services, commands, an Android phone),
    then say a song is playing. Prints every answer, so we learn what the band makes of it."""
    from . import capabilities as caps

    conn, band, _ = await _connect_authed(args, store)
    try:
        services = caps.services_from(await band.request(caps.supported_services()))
        for req in caps.supported_commands(services, band.session.params.slice_size):
            await band.request(req)
        out("services and commands announced")
        for name, req in (("phone info (Android 14)", caps.phone_info()), ("connect status", caps.connect_status()),
                          ("default switch", caps.default_switch())):
            try:
                out(f"{name}: {await band.request(req, timeout=4.0)!r}")
            except BandError as e:
                out(f"{name}: {e}")
        try:
            out(f"music info: {await band.request(controls.music_info('Openband', 'ready'), timeout=4.0)!r}")
        except BandError as e:
            out(f"music info: {e}")
        out("Staying connected for 20 s: open the band's app list and look for Music.")
        await asyncio.sleep(20)
    finally:
        await conn.__aexit__(None, None, None)
    return 0


async def do_key(args, store: Store) -> int:
    """Print the pairing record as one line, for the iPhone app ("Use my Mac's key")."""
    recs = [r for r in store.all() if r.bonded and (not args.address or r.address == args.address)]
    if not recs:
        out("No paired band. Run `openband pair` first.")
        return 1
    r = recs[0]
    out(f"openband-key:v1:{r.secret_key}:{r.client_mac}:{r.device_uuid}:{r.band_mac}")
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
    sub.add_parser("announce", help="experimental: present as an Android phone, to unlock band features")
    sub.add_parser("caps", help="announce what Openband supports; print what the band supports")
    sub.add_parser("key", help="print the pairing key as one line, to share it with the iPhone app (keep it private)")

    s = sub.add_parser("notify", help="show a notification on the band")
    s.add_argument("title")
    s.add_argument("text", nargs="?", default="")
    s.add_argument("--sender", default="Openband")
    s.add_argument("--music", action="store_true",
                   help="write it on the band's music screen (no buzz) instead; needs a running `listen`")
    s.add_argument("--no-bluetooth", action="store_true",
                   help="only hand it to a running `openband listen`; never open Bluetooth (for hooks run in Warp or an IDE)")

    s = sub.add_parser("listen", help="react to taps on the band (find phone, music buttons) and pass on `openband notify`")
    s.add_argument("--exec", help="shell command run on every press; $OPENBAND_BUTTON holds the button, "
                   "the last line it prints is shown on the band")
    s.add_argument("--title", default="Openband", help="what the band's music screen shows as the artist")
    return p


COMMANDS = {
    "scan": do_scan,
    "probe": do_probe,
    "pair": do_pair,
    "status": do_status,
    "set-time": do_set_time,
    "sync": do_sync,
    "forget": do_forget,
    "key": do_key,
    "caps": do_caps,
    "announce": do_announce,
    "notify": do_notify,
    "listen": do_listen,
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
