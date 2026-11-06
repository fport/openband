<p align="center">English · <a href="README.tr.md">Türkçe</a></p>

<p align="center">
  <img src="docs/icon.svg" width="112" alt="Openband icon: a band with an open orange ring">
</p>

<h1 align="center">Openband</h1>

<p align="center"><b>Read your Huawei Band 6 without Huawei Health or a Huawei account.</b><br>
Over Bluetooth LE, from your computer. Your data stays with you.</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-ededed?labelColor=1c1c1c" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/python-3.11%2B-ededed?labelColor=1c1c1c" alt="Python 3.11+">
  <a href="https://github.com/fport/openband/actions/workflows/ci.yml"><img src="https://img.shields.io/github/actions/workflow/status/fport/openband/ci.yml?branch=main&labelColor=1c1c1c&label=tests" alt="Tests"></a>
  <img src="https://img.shields.io/badge/Huawei%20Band%206-BLE-ff7a1a?labelColor=1c1c1c" alt="Huawei Band 6 over BLE">
</p>

**Status:** early. The protocol code passes against vectors from Gadgetbridge's own Java code and a
simulated band. It has not yet been run against a real Band 6; the first step below is the one that
tells us which pairing path your band uses.

## Start

```bash
git clone https://github.com/fport/openband && cd openband
uv sync
uv run openband scan       # find the band
uv run openband probe      # read its link parameters; changes nothing
uv run openband pair       # hand the band a key of our own (read the note below first)
uv run openband status     # battery, today's steps, firmware
uv run openband sync --days 7 --format csv
```

Before you start, turn off Bluetooth on the phone the band is paired with (or close Huawei Health),
otherwise the phone holds the connection and the band does not show up.

On macOS, run Openband from Terminal or iTerm and allow Bluetooth when asked. A process without
Bluetooth permission is stopped by macOS (exit code 134), which is what happens inside some IDE
and agent shells.

## Why

Huawei Health needs an account, sends your data to Huawei's servers and decides what you may export.
The band itself speaks a documented-by-others protocol over Bluetooth LE. Openband speaks it directly:
the pairing key is created on your computer, and history goes to a JSON or CSV file you own.

It is the Huawei sibling of [Freeband](https://github.com/cobanov/freeband), which does the same for
Xiaomi bands. The approach is borrowed from there: work out the protocol, check it against known
values, keep the key local, never delete anything from the band.

## What works

| Feature | State |
|---|---|
| Framing, slicing, CRC16, TLV, AES-CBC/GCM | done; matches Gadgetbridge vectors |
| Pairing, normal mode (support type 0) | done; needs the band's MAC from Settings > About |
| Pairing, HiChain Lite (PIN and key variants) | done |
| Full HiChain (SPEKE) | not built; Openband stops with a clear message if a band asks for it |
| Battery, firmware, today's steps, kcal and distance | done |
| Set the clock | done |
| Per-minute history: steps, kcal, distance, heart rate, SpO2, resting heart rate | done |
| Sleep: light and deep spans | done |
| TruSleep stages (REM, awake), workouts, stress | not built yet (file-transfer service) |
| Notifications, alarms, settings | not built yet |
| iPhone app | planned, after the protocol is confirmed on a real band |

Each row marked done is covered by tests; none has been checked against a real band yet.

## Pairing, and what it does to Huawei Health

`openband pair` gives the band a new 16-byte key that only your computer knows. After that:

- Huawei Health loses the band and has to pair again to use it. Pairing there again most likely
  replaces Openband's key; run `openband pair --again` to come back.
- Nothing is deleted from the band. Openband only reads history.
- The key lives in `~/.config/openband/bands.json`, readable only by you.

## More

- [docs/PROTOCOL.md](docs/PROTOCOL.md): frames, TLV, handshake, data commands.
- `uv run pytest`: the test suite, including the Gadgetbridge cross-check.
- `uv run openband -vv <command>`: every byte on the wire, for bug reports.

## License

MIT. The protocol knowledge comes from [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge)'s
Huawei support; Openband's code is its own.
