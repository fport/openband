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

**Status:** early, and working on a real Band 6 (firmware 11.1.3.20): pairing, reconnecting with the
stored key, battery, firmware, today's totals and setting the clock. Per-minute history and sleep
pass against Gadgetbridge vectors and a simulated band and still wait for a band that was worn.

## Start

```bash
git clone https://github.com/fport/openband && cd openband
uv sync
uv run openband scan       # find the band
uv run openband probe      # read its link parameters; changes nothing
uv run openband pair       # hand the band a key of our own (read the note below first)
uv run openband status     # battery, today's steps, firmware
uv run openband sync --days 7 --format csv
uv run openband listen     # stay connected: taps on the band, notifications from any shell
uv run openband notify "Claude" "tests pass" --no-bluetooth
```

Before you start, turn off Bluetooth on the phone the band is paired with (Settings > Bluetooth, not
just Control Center) and close Huawei Health, otherwise the phone holds the connection and the band
does not show up. Once Openband is paired, Huawei Health can no longer connect, so the phone can stay on.

The band only advertises for a short while after its screen wakes up. Wake it before each command;
Openband waits up to 90 seconds (`--wait`) and connects as soon as the band appears.

On macOS, run Openband from Terminal or iTerm and allow Bluetooth when asked. A process without
Bluetooth permission is stopped by macOS (exit code 134, often with no message), which is what
happens in Warp and inside some IDE and agent shells.

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
| Pairing, normal mode (support type 0 or 8; the Band 6) | done, works on a real band; needs the band's MAC from Settings > About |
| Pairing, HiChain Lite (PIN and key variants) | done |
| Full HiChain (SPEKE) | not built; Openband stops with a clear message if a band asks for it |
| Battery, firmware, today's steps, kcal and distance | done |
| Set the clock | done |
| Per-minute history: steps, kcal, distance, heart rate, SpO2, resting heart rate | done |
| Sleep: light and deep spans | done |
| TruSleep stages (REM, awake), workouts, stress | not built yet (file-transfer service) |
| Notifications from the computer (`notify`), through a running `listen` | done, works on a real band |
| Taps on the band ("Find phone", music buttons) as events and commands (`listen --exec`) | done; "Find phone" works on a real band |
| Claude Code hooks: the band buzzes when Claude needs you or finishes | done (`scripts/claude_hook.py`) |
| iPhone app (Freeband's screens and scores on the Huawei protocol) | builds and runs in the simulator; not yet tried on a phone |
| Workouts on the phone: run, ride, swim, walk and seven more, with a GPS route | done in the app; the route comes from the iPhone, since the Band 6 has no GPS |
| A share card: the shape of your route, three figures, square or story, clear background for a sticker | done in the app |
| Apple Health both ways, including workouts and their routes | done in the app; see the notes in `ios/Openband/Integrations/AppleHealth.swift` |
| Coach: a meal photo or a body check-in read by a model, with your own API key | done in the app; the key stays in the phone's keychain |
| Alarms, band settings, workouts recorded on the band itself | not built yet |

Each row marked done is covered by tests. Checked on a real Band 6 so far: normal-mode pairing,
reconnecting, battery, firmware, today's totals, setting the clock.

## Pairing, and what it does to Huawei Health

`openband pair` gives the band a new 16-byte key that only your computer knows. After that:

- Huawei Health loses the band and has to pair again to use it. Pairing there again most likely
  replaces Openband's key; run `openband pair --again` to come back.
- Nothing is deleted from the band. Openband only reads history.
- The key lives in `~/.config/openband/bands.json`, readable only by you.

## Claude Code on your wrist

Keep `openband listen` running in Terminal, then add two hooks to `~/.claude/settings.json`:

```json
"hooks": {
  "Notification": [{"hooks": [{"type": "command", "command": "python3 /path/to/openband/scripts/claude_hook.py", "async": true}]}],
  "Stop": [{"hooks": [{"type": "command", "command": "python3 /path/to/openband/scripts/claude_hook.py", "async": true}]}]
}
```

The hook talks to `listen` over a local socket, so it works from Warp or an IDE too, where
Bluetooth itself would be refused.

## iPhone app

`ios/` holds the app: [Freeband](https://github.com/cobanov/freeband)'s screens, scores and
storage on top of a Swift port of Openband's protocol (`ios/Openband/Band/Huawei`).

Five tabs. **Today** is the day's verdict and the three scores. **Move** records a workout — run,
ride, swim, walk, and seven more behind a menu — follows the route on the phone's GPS, and turns
the finished one into a card you can post: the shape of where you went, three figures, square or
story, and a clear background when you want it as a sticker over your own photo. **Sleep** is the
night. **Coach** reads a meal photo or a body check-in. **Band** is the device and the settings.

Workouts go to Apple Health as real `HKWorkout`s with their route attached, so they count towards
the rings and show up in Fitness. What the band measured goes out too — steps, heart rate, blood
oxygen, sleep — attributed to the band rather than to the phone, with a sync identifier per record
so syncing again replaces instead of duplicating. Each band remembers how far it has exported, so
a sync sends the new minutes and today again rather than rewriting the overlap every time.

Steps go the other way to fill the minutes the band has nothing for, and that read is anchored:
Health is asked what has changed since the last pass instead of for a fixed 90 days, and a step
sample deleted in Health stops filling the minute it filled. The anchor itself can only be checked
on a real iPhone — a simulator's Health store is empty.

### Coach, and your own API key

Coach is the one part of Openband that talks to a server, and it is not Openband's server. You
paste an Anthropic or OpenAI key; it is kept in this phone's keychain, not in `UserDefaults`, not
in iCloud and not in a backup. A meal photo or a body check-in goes from the phone straight to the
provider you chose, on your account, and the answer comes straight back. Openband has no AI
account, sees neither the photo nor the key, and the app strips the location and camera details
from a photo before it goes.

What comes back is an estimate and is labelled as one: calories arrive as a range, not a figure,
a body-fat read is a span of several points, and nothing from Coach is written to Apple Health.
It is not medical advice, and the screens say so.

### Design

[docs/DESIGN.md](docs/DESIGN.md) is the design language: one accent, a warm neutral ground, Plus
Jakarta Sans with IBM Plex Mono for readouts, one container and one motion curve. The tokens are
the source, not the Swift:

```bash
python3 -I scripts/gen_tokens.py   # design/tokens.json -> Tokens.generated.swift
```

```bash
brew install xcodegen
cd ios && xcodegen generate && open Openband.xcodeproj
```

In Xcode pick your Apple ID under Signing & Capabilities (a free account works; the app then runs
for 7 days before Xcode has to install it again), plug in the iPhone and run. To keep using the
Mac's pairing, choose "Use my Mac's key" when pairing and paste the line `openband key` prints.

## More

- [docs/PROTOCOL.md](docs/PROTOCOL.md): frames, TLV, handshake, data commands.
- `uv run pytest`: the test suite, including the Gadgetbridge cross-check.
- `cd ios/tests/protocol && swiftc ../../Openband/Band/Huawei/*.swift FakeBand.swift main.swift -o /tmp/hw && /tmp/hw`:
  the same checks for the Swift port. `ios/tests/analytics` does the scores, `ios/tests/workouts`
  the route geometry, splits and pace.
- `uv run openband -vv <command>`: every byte on the wire, for bug reports.

## License

MIT. The protocol knowledge comes from [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge)'s
Huawei support; the protocol code is Openband's own. The iPhone app is built on
[Freeband](https://github.com/cobanov/freeband) (MIT, Mert Cobanov); its notice is in LICENSE.
