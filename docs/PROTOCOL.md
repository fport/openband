# The Huawei link, as Openband speaks it

What a Huawei Band 6 expects over Bluetooth LE, written down from Gadgetbridge's Huawei support
(`devices/huawei` and `service/devices/huawei` in [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge))
and checked against vectors produced by its Java code (`tests/vectors/gadgetbridge.json`).

## Transport

| | |
|---|---|
| Service | `FE86` |
| Write | `FE01` |
| Notify | `FE02` |
| OS-level bonding | none; all security is in the application protocol |

## Frames

```
5A | len (2, BE) | slice | [flag] | service | command | TLV body | CRC16 (2, BE)
```

- `len` counts the bytes from `slice` up to the CRC.
- `slice` 0: unsliced. 1, 2, 3: first, middle, last slice of a longer message, each followed by a
  running `flag` byte. Only the first slice carries service and command.
- The slice size comes from LinkParams (default 0xF4).
- CRC16 is CRC-16/XMODEM (poly 0x1021, init 0) over everything before it.

## TLV

One-byte tag, length as a big-endian base-128 varint (high bit = more bytes follow), value.
Tags 0x80 and up hold nested TLVs. Integers are big-endian. Tag `0x7F` carries a result code;
100000 (`0x000186A0`) means success.

Encrypted bodies are replaced by `7C=01, 7D=IV, 7E=ciphertext`. The cipher is AES-128-CBC with
PKCS#7 padding, or AES-128-GCM (16-byte tag) when LinkParams says `encrypt_method = 1`. The IV is
12 random bytes followed by a 4-byte counter that starts from the value the band gives in
BondParams and goes up by one per message.

## Handshake (service 0x01)

| Step | Command | Encrypted | What |
|---|---|---|---|
| 1 | `01` LinkParams | no | slice size, MTU, auth version, server nonce (tag 05: `?, auth_version, nonce16`), support type (07), auth algo (08), encrypt method (0C) |
| 2 | `33` SecurityNegotiation | no | only for support types 1-4; the answer picks HiChain Lite (1 or 2) or full HiChain. Types 0 and 8 skip it and use normal mode |
| 3 | `2C` PinCode | no | HiChain Lite with auth version != 2: the band's PIN, encrypted with the digest secret |
| 4 | `13` Auth | no | `01` = challenge (32 bytes), `02` = auth version (2 bytes) + client nonce; the band answers with the expected response |
| 5 | `0F` BondParams | no | our serial and (made-up) MAC; the band answers with bond status and the IV counter |
| 6 | `0E` Bond | no | our 16-byte session key, encrypted with the bond key, and its IV |

**Challenge.** Nonce = server nonce + client nonce.

- Normal mode: `step1 = HMAC(digest_secret + msg, nonce)`, `digest = HMAC(step1, nonce) + step1`.
- HiChain Lite, auth version 2: `k = secret_key + msg`, `digest = HMAC(k, nonce) + k`.
- HiChain Lite otherwise: the digest secret is XORed with `SHA256(HEX(PIN))`, then as normal
  mode, with PBKDF2-SHA256 (1000 rounds, over the hex strings) in place of step 1 when
  `auth_algo = 1`.

`msg` is `01 00` for the challenge and `01 10` for the response. The first 32 bytes go on the wire.

**Bond key.** HiChain Lite wraps our session key with the first 16 bytes of the challenge digest.
Normal mode wraps it with a key derived from the band's own Bluetooth MAC, which is why
`openband pair` asks for `--band-mac` on normal-mode bands. CoreBluetooth on macOS and iOS
never reveals a device's MAC, but the band shows it under Settings > About.

The session key is ours: 16 random bytes created on your computer. No account or server.

**Seen on a real Band 6** (model `Fara-B19`, firmware 11.1.3.20): protocol version 2, auth version 1,
support type 8, auth algo 1, encrypt method 0 (AES-CBC), slice size and MTU 244. That is normal mode.
The Bond answer comes about four seconds after the request. Right after Bond the band sends an
encrypted `0F/03` that cannot be read yet; the next one, `0F/03 01=0001`, decrypts fine.

## Data (service 0x07)

| Command | Request | Answer |
|---|---|---|
| `03` totals | `01` | `81{83{05 steps, 06 kcal, 07 metres}...}` |
| `0A` / `0B` activity count / record | `81, 03 start, 04 end` / `81{02 index}` | `81{02 count}` / `81{02 index, 03 base time, 84{05 minute offset, 06 data}...}` |
| `0C` / `0D` sleep count / record | same | `81{02 index, 83{04 type, 05 start(4)+minutes(2)}...}` |

Activity data per minute: a bitmap byte, a second one when bit 0x80 is set, then the values.
Bitmap 1: `02` steps, `04` kcal, `08` metres, `40` heart rate (1 byte), `01` and `10` unknown
(2 bytes), `20` unknown (1 byte). Bitmap 2 (1 byte each): `01` SpO2, `02` resting heart rate.

Sleep types: `06` light, `07` deep. Bands with TruSleep (the Band 6 among them) keep the detailed
stages (REM, awake) in files fetched through a separate file-transfer service; Openband does not
read those yet.

## Device config after auth

| Command | |
|---|---|
| `05` time | `01` unix time (4), `02` zone: hours (+128 west of UTC), minutes |
| `07` product info | model (0A), firmware (07), serial (09) |
| `08` battery | `01` percent; `27` is the unsolicited "battery changed" message |
