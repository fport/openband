import Foundation

// Standalone harness for the Swift Huawei protocol port:
//   cd ios/tests/protocol && swiftc ../../Openband/Band/Huawei/*.swift FakeBand.swift main.swift -o hwproto && ./hwproto
// Checks the Gadgetbridge vectors (tests/vectors/gadgetbridge.json at the repo root), the codec
// cases of tests/test_codec.py, a real Band 6 frame, and every handshake of tests/test_handshake.py
// against the simulated band.

var failures: [String] = []
var groupFailures = 0

func check(_ ok: Bool, _ what: @autoclosure () -> String) {
    if !ok {
        failures.append(what())
        groupFailures += 1
    }
}

func checkThrows<T>(_ what: String, _ body: () throws -> T) {
    do {
        _ = try body()
        check(false, "\(what): expected an error")
    } catch {}
}

func group(_ name: String, _ body: () throws -> Void) {
    groupFailures = 0
    do { try body() } catch { check(false, "\(name): threw \(error)") }
    print(groupFailures == 0 ? "PASS \(name)" : "FAIL \(name) (\(groupFailures))")
}

@MainActor
func groupAsync(_ name: String, _ body: () async throws -> Void) async {
    groupFailures = 0
    do { try await body() } catch { check(false, "\(name): threw \(error)") }
    print(groupFailures == 0 ? "PASS \(name)" : "FAIL \(name) (\(groupFailures))")
}

func hex(_ s: String) -> Data { huaweiData(hex: s)! }

// MARK: vectors

let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
let here = URL(fileURLWithPath: #filePath, relativeTo: cwd).absoluteURL.deletingLastPathComponent()
let vectorsURL = ProcessInfo.processInfo.environment["OPENBAND_VECTORS"].map { URL(fileURLWithPath: $0) }
    ?? here.appendingPathComponent("../../../tests/vectors/gadgetbridge.json").standardizedFileURL
let vectors = (try JSONSerialization.jsonObject(with: Data(contentsOf: vectorsURL))) as! [[String: Any]]
func of(_ kind: String) -> [[String: Any]] { vectors.filter { $0["kind"] as? String == kind } }

group("vectors: digest (\(of("digest").count))") {
    for v in of("digest") {
        let mode = v["auth_mode"] as! Int, version = v["auth_version"] as! Int, algo = v["auth_algo"] as! Int
        let key = (v["key"] as? String).map(hex)
        let nonce = hex(v["nonce"] as! String)
        let label = "digest mode\(mode) v\(version) algo\(algo)"
        let c = try HuaweiCrypto.digestChallenge(nonce: nonce, authVersion: version, authMode: mode, authAlgo: algo, key: key)
        let r = try HuaweiCrypto.digestResponse(nonce: nonce, authVersion: version, authMode: mode, authAlgo: algo, key: key)
        check(huaweiHex(c) == v["challenge"] as! String, "\(label) challenge")
        check(huaweiHex(r) == v["response"] as! String, "\(label) response")
    }
}

group("vectors: mac_key (\(of("mac_key").count))") {
    for v in of("mac_key") {
        let k = try HuaweiCrypto.macBondKey(bandMAC: v["mac"] as! String, authVersion: v["auth_version"] as! Int)
        check(huaweiHex(k) == v["key"] as! String, "mac_key v\(v["auth_version"]!)")
    }
}

group("vectors: aes (\(of("aes").count))") {
    for v in of("aes") {
        let gcm = v["gcm"] as! Bool
        let key = hex(v["key"] as! String), iv = hex(v["iv"] as! String), plain = hex(v["plain"] as! String)
        let cipher = try HuaweiCrypto.encrypt(useGCM: gcm, data: plain, key: key, iv: iv)
        check(huaweiHex(cipher) == v["cipher"] as! String, "aes gcm=\(gcm) encrypt")
        check(try HuaweiCrypto.decrypt(useGCM: gcm, data: hex(v["cipher"] as! String), key: key, iv: iv) == plain, "aes gcm=\(gcm) decrypt")
    }
}

group("vectors: crc16 (\(of("crc16").count))") {
    for v in of("crc16") {
        check(Int(HuaweiFrame.crc16(hex(v["data"] as! String))) == v["crc"] as! Int, "crc16 \(v["data"]!)")
    }
}

group("vectors: varint (\(of("varint").count))") {
    for v in of("varint") {
        let value = v["value"] as! Int, bytes = v["bytes"] as! String
        check(huaweiHex(huaweiEncodeVarint(value)) == bytes, "varint encode \(value)")
        let d = try huaweiDecodeVarint([UInt8](hex(bytes)), at: 0)
        check(d.value == value && d.used == bytes.count / 2, "varint decode \(value)")
    }
}

group("vectors: frame (\(of("frame").count))") {
    for v in of("frame") {
        let body = hex(v["body"] as! String)
        let service = UInt8(v["service"] as! Int), command = UInt8(v["command"] as! Int), slice = v["slice_size"] as! Int
        let packets = try HuaweiFrame.encode(service: service, command: command, body: body, sliceSize: slice)
        check(packets.map(huaweiHex) == v["packets"] as! [String], "frame \(body.count)B slice \(slice) packets")
        var r = HuaweiReassembler()
        let msgs = try r.feed(packets.reduce(Data(), +))
        check(msgs == [HuaweiMessage(service: service, command: command, body: body)], "frame \(body.count)B slice \(slice) reassembly")
    }
}

// MARK: codec (tests/test_codec.py)

group("codec: TLV") {
    let inner = HuaweiTLV().put(0x02, u16: 7)
    let t = HuaweiTLV().put(0x01).put(0x81, tlv: inner).put(0x05, Data(repeating: UInt8(ascii: "x"), count: 300))
    let parsed = try HuaweiTLV.parse(t.serialize())
    check(try parsed.get(0x01) == Data(), "empty value")
    check(try parsed.child(0x81).uint(0x02) == 7, "nested uint")
    check(try parsed.get(0x05).count == 300, "long value")
    checkThrows("missing tag") { try HuaweiTLV().get(0x09) }
    checkThrows("truncated") { try HuaweiTLV.parse(Data([0x01, 0x05, 0x00])) }
    check(try HuaweiTLV.parse(Data([0x01, 0x01, 0x07, 0x00])).byte(0x01) == 7, "trailing zero ignored")
}

group("codec: reassembler") {
    let a = try HuaweiFrame.encode(service: 1, command: 8, body: HuaweiTLV().put(0x01, byte: 55).serialize())
    let big = Data((0 ..< 512).map { UInt8($0 & 0xFF) })
    let b = try HuaweiFrame.encode(service: 7, command: 11, body: big, sliceSize: 60)
    let stream = (a + b).reduce(Data(), +)
    var r = HuaweiReassembler()
    var got: [HuaweiMessage] = []
    var i = 0
    while i < stream.count {
        got += try r.feed(stream.subdata(in: i ..< min(i + 7, stream.count)))
        i += 7
    }
    check(got.map { [$0.service, $0.command] } == [[1, 8], [7, 11]], "split and glued notifications")
    check(got.count == 2 && got[1].body == big, "sliced body")
    var p = [UInt8](try HuaweiFrame.encode(service: 1, command: 1, body: Data([0x01, 0x00]))[0])
    p[p.count - 1] ^= 0xFF
    var r2 = HuaweiReassembler()
    checkThrows("bad crc") { try r2.feed(Data(p)) }
}

group("codec: minute records") {
    let m = try HuaweiCommands.parseMinute(timestamp: 1000, data: Data([0xCE, 0x03, 0x00, 0x2A, 0x00, 0x05, 0x00, 0x20, 0x48, 0x61, 0x3C]))
    check(m.steps == 42 && m.kcal == 5 && m.distance == 32 && m.heartRate == 72 && m.spo2 == 97 && m.restingHR == 60, "all fields")
    check(m.unknown.isEmpty, "no unknowns")
    let u = try HuaweiCommands.parseMinute(timestamp: 0, data: Data([0x21, 0x12, 0x34, 0x09]))
    check(u.unknown == ["b1_01": 0x1234, "b1_20": 9] && u.steps == nil, "unknown fields kept")
    checkThrows("too short") { try HuaweiCommands.parseMinute(timestamp: 0, data: Data([0x02, 0x01])) }
}

group("codec: step and sleep records") {
    let step = HuaweiTLV().put(0x81, tlv: HuaweiTLV()
        .put(0x02, u16: 3)
        .put(0x03, u32: 1_700_000_000)
        .put(0x84, tlv: HuaweiTLV().put(0x05, byte: 0).put(0x06, Data([0x02, 0x00, 0x10])))
        .put(0x84, tlv: HuaweiTLV().put(0x05, byte: 2).put(0x06, Data([0x40, 0x50]))))
    let r = try HuaweiCommands.parseStepData(step)
    check(r.number == 3, "record number")
    check(r.samples.map { [$0.unixTime, $0.steps ?? -1, $0.heartRate ?? -1] } == [[1_700_000_000, 16, -1], [1_700_000_120, -1, 80]], "minutes")
    let ts = huaweiBytesBE(1_700_000_000, size: 4) + huaweiBytesBE(90, size: 2)
    let sleep = HuaweiTLV().put(0x81, tlv: HuaweiTLV().put(0x02, u16: 0).put(0x83, tlv: HuaweiTLV().put(0x04, byte: 7).put(0x05, ts)))
    let s = try HuaweiCommands.parseSleepData(sleep)
    check(s.spans.first?.kind == .deep && s.spans.first?.end.timeIntervalSince(s.spans[0].start) == 5400, "deep span")
}

group("codec: time zone packing") {
    let now = Date(timeIntervalSince1970: 1_762_430_400)  // 2026-11-06 12:00 UTC
    for (minutes, packed) in [(180, 0x0300), (0, 0x0000), (-300, 0x8500), (330, 0x051E), (-210, (0x83 << 8) | 0xE2)] {
        let tz = TimeZone(secondsFromGMT: minutes * 60)!
        let r = HuaweiCommands.timeAndZone(now, timeZone: tz)
        check(r.unix == 1_762_430_400 && r.zone == packed, "zone \(minutes) min -> \(String(format: "%04x", r.zone))")
    }
}

group("codec: security negotiation") {
    check(HuaweiCommands.parseSecurityNegotiation(HuaweiTLV().put(0x02, byte: 2)) == 2, "lite 2")
    check(HuaweiCommands.parseSecurityNegotiation(HuaweiTLV().put(0x01, byte: 1)) == HuaweiCommands.hiChainFull, "full")
    check(HuaweiCommands.isHiChain3(HuaweiCommands.parseSecurityNegotiation(HuaweiTLV().put(0x01, byte: 4).put(0x02, byte: 1))), "hichain3")
}

group("real Band 6 LinkParams (fw 11.1.3.20)") {
    var r = HuaweiReassembler()
    let msgs = try r.feed(hex("5a002f000101010102020200f4030200f40402000005120001fabdd6987ab4823fd95c1cd57de5565d070108080101090102bf13"))
    check(msgs.count == 1 && msgs[0].service == 1 && msgs[0].command == 1, "one 01/01 message")
    let p = try HuaweiLinkParams(tlv: try HuaweiTLV.parse(msgs[0].body))
    check(p.protocolVersion == 2 && p.authVersion == 1 && p.deviceSupportType == 8 && p.authAlgo == 1 && p.encryptMethod == 0,
          "params \(p)")
    check(p.sliceSize == 244 && p.mtu == 244 && p.bondState == 2, "sizes and bond state")
    check(!p.usesHiChain && p.path == "normal", "normal mode")
    check(huaweiHex(p.serverNonce) == "fabdd6987ab4823fd95c1cd57de5565d", "server nonce")
    // The request Openband sent, byte for byte.
    let req = try HuaweiFrame.encode(service: 1, command: 1, body: HuaweiCommands.linkParams().tlv.serialize())
    check(req.map(huaweiHex) == ["5a000b0001010100020003000400f13b"], "link params request bytes")
}

// MARK: handshake (tests/test_handshake.py)

func record(_ cfg: BandConfig) -> HuaweiBandRecord { HuaweiBandRecord.new(bandMAC: cfg.mac) }

@MainActor
func runHandshakes() async {
    let paths: [(String, BandConfig)] = [
        ("normal-v2", BandConfig(supportType: 0, authVersion: 2)),
        ("normal-v1-gcm", BandConfig(supportType: 0, authVersion: 1, encryptMethod: 1)),
        ("normal-band6 (type 8, v1, algo 1)", BandConfig(supportType: 8, authVersion: 1, authAlgo: 1)),
        ("hichain-lite-pin", BandConfig(supportType: 2, authVersion: 3)),
        ("hichain-lite-pin-pbkdf2", BandConfig(supportType: 2, authVersion: 3, authAlgo: 1)),
        ("hichain-lite-v2-key", BandConfig(supportType: 2, authVersion: 2)),
        ("hichain-lite-gcm", BandConfig(supportType: 1, authVersion: 3, encryptMethod: 1, negotiatedAuthType: 1)),
        ("bond-unanswered", BandConfig(supportType: 2, authVersion: 3, answerBond: false)),
    ]
    for (name, cfg) in paths {
        await groupAsync("handshake: \(name)") {
            let rec = record(cfg)
            let fake = FakeBand(cfg, clientKey: rec.secretKey)
            let channel = fake.connect(timeout: cfg.answerBond ? 2 : 1)
            let report = try await huaweiAuthenticate(channel, record: rec, allowBond: true)
            check(report.bondedNow, "\(name): bonded now")
            check(fake.sessionKey == rec.secretKey, "\(name): band holds our key")
            let details = try await huaweiAfterAuth(channel)
            check(details.battery == 77, "\(name): battery")
            check(details.product.model == "FRA-B19" && details.product.softwareVersion == "1.0.1.36", "\(name): product \(details.product)")
            try await huaweiSetTime(channel)
            let totals = try await huaweiFitnessTotals(channel)
            check(totals == HuaweiTotals(steps: 1234, calories: 56, distanceMeters: 900), "\(name): totals")
        }
    }

    await groupAsync("handshake: refuses to bond without permission") {
        let cfg = BandConfig()
        do {
            _ = try await huaweiAuthenticate(FakeBand(cfg).connect(), record: record(cfg), allowBond: false)
            check(false, "expected needsBond")
        } catch HuaweiError.needsBond {}
    }

    await groupAsync("handshake: normal mode needs the band MAC") {
        let cfg = BandConfig(supportType: 0, authVersion: 2)
        var rec = record(cfg)
        rec.bandMAC = ""
        do {
            _ = try await huaweiAuthenticate(FakeBand(cfg).connect(), record: rec, allowBond: true)
            check(false, "expected needsBandMAC")
        } catch HuaweiError.needsBandMAC {}
    }

    final class FullHiChainBand: FakeBand {
        override func handle(_ id: HuaweiCommandID, _ t: HuaweiTLV) throws -> (Bool, HuaweiTLV)? {
            if id == HuaweiCommandID(service: 1, command: HuaweiCommands.securityNegotiationID) {
                return (false, HuaweiTLV().put(0x01, byte: 1))
            }
            return try super.handle(id, t)
        }
    }
    await groupAsync("handshake: full HiChain is reported") {
        let cfg = BandConfig(supportType: 1, negotiatedAuthType: 0)
        do {
            _ = try await huaweiAuthenticate(FullHiChainBand(cfg).connect(), record: record(cfg), allowBond: true)
            check(false, "expected hiChainUnsupported")
        } catch HuaweiError.hiChainUnsupported(let type) {
            check(type == HuaweiCommands.hiChainFull, "auth type \(type)")
        }
    }

    /// Hands out PIN 482913 but checks the challenge against 000000.
    final class WrongPinBand: FakeBand {
        override func handle(_ id: HuaweiCommandID, _ t: HuaweiTLV) throws -> (Bool, HuaweiTLV)? {
            if id == HuaweiCommandID(service: 1, command: HuaweiCommands.pinCodeID) {
                cfg.pin = Data("482913".utf8)
                defer { cfg.pin = Data("000000".utf8) }
                return try super.handle(id, t)
            }
            return try super.handle(id, t)
        }
    }
    await groupAsync("handshake: wrong PIN fails the challenge") {
        var cfg = BandConfig()
        cfg.pin = Data("000000".utf8)
        do {
            _ = try await huaweiAuthenticate(WrongPinBand(cfg).connect(), record: record(BandConfig()), allowBond: true)
            check(false, "expected refused")
        } catch HuaweiError.refused {}
    }

    await groupAsync("handshake: reconnect with the stored record") {
        let cfg = BandConfig(supportType: 0, authVersion: 2, bondStatus: 1)
        var rec = record(cfg)
        rec.bonded = true
        let stored = try JSONEncoder().encode(rec)
        let again = try JSONDecoder().decode(HuaweiBandRecord.self, from: stored)
        check(again == rec, "record survives JSON")
        let fake = FakeBand(cfg, sessionKey: again.secretKey)
        let channel = fake.connect()
        let report = try await huaweiAuthenticate(channel, record: again, allowBond: false)
        check(!report.bondedNow, "not bonded again")
        check(!fake.seen.contains(HuaweiCommandID(service: 1, command: HuaweiCommands.bondID)), "bond skipped")
        check(try await huaweiAfterAuth(channel).battery == 77, "battery after reconnect")
    }

    await groupAsync("sync: minutes, and a missing sleep list") {
        let cfg = BandConfig()
        let rec = record(cfg)
        let fake = FakeBand(cfg)
        let base = 1_762_400_000
        for n in 0 ..< 2 {
            var minutes = HuaweiTLV().put(0x02, u16: n).put(0x03, u32: base + n * 3600)
            for off in 0 ..< 3 {
                minutes = minutes.put(0x84, tlv: HuaweiTLV().put(0x05, byte: off)
                    .put(0x06, Data([0xC2, 0x01, 0x00, UInt8(10 + off), UInt8(70 + off), 98])))
            }
            fake.stepsRecords.append(HuaweiTLV().put(0x81, tlv: minutes))
        }
        let channel = fake.connect()
        _ = try await huaweiAuthenticate(channel, record: rec, allowBond: true)
        var steps: [Int] = []
        let h = try await huaweiFetchHistory(channel, start: Date(timeIntervalSince1970: TimeInterval(base - 60)),
                                             end: Date(timeIntervalSince1970: TimeInterval(base + 7200))) { kind, n in
            if kind == "activity" { steps.append(n) }
        }
        check(h.minutes.count == 6, "six minutes")
        check(h.minutes.first?.steps == 10 && h.minutes.first?.heartRate == 70 && h.minutes.first?.spo2 == 98, "first minute")
        check(h.minutes.last?.unixTime == base + 3600 + 120, "last minute time")
        check(h.sleep.isEmpty && h.errors.isEmpty, "no sleep, no errors")
        check(steps == [3, 6], "progress \(steps)")
    }

    await groupAsync("channel: timeout and disconnect") {
        final class SilentBand: FakeBand {
            override func handle(_ id: HuaweiCommandID, _ t: HuaweiTLV) throws -> (Bool, HuaweiTLV)? { nil }
        }
        let channel = SilentBand().connect(timeout: 0.2)
        do {
            _ = try await channel.request(HuaweiCommands.linkParams())
            check(false, "expected timeout")
        } catch HuaweiError.timeout {}
        async let pending = channel.request(HuaweiCommands.linkParams(), timeout: 5)
        try await Task.sleep(nanoseconds: 50_000_000)
        channel.fail(HuaweiError.disconnected)
        do {
            _ = try await pending
            check(false, "expected disconnected")
        } catch HuaweiError.disconnected {}
        do {
            _ = try await channel.request(HuaweiCommands.linkParams())
            check(false, "expected disconnected after close")
        } catch HuaweiError.disconnected {}
    }
}

group("shared key from `openband key`") {
    let line = "openband-key:v1:00112233445566778899AABBCCDDEEFF:FF:FF:FF:12:34:56:0123456789ABCDEF0123456789ABCDEF:AA:BB:CC:DD:EE:F1"
    guard let r = HuaweiBandRecord.fromSharedKey(line) else { check(false, "did not parse"); return }
    check(huaweiHex(r.secretKey).uppercased() == "00112233445566778899AABBCCDDEEFF", "secret")
    check(r.clientMAC == "FF:FF:FF:12:34:56", "client MAC \(r.clientMAC)")
    check(r.deviceUUID == "0123456789ABCDEF0123456789ABCDEF", "uuid")
    check(r.bandMAC == "AA:BB:CC:DD:EE:F1", "band MAC \(String(describing: r.bandMAC))")
    check(r.bonded, "bonded")
    check(String(decoding: r.clientSerial, as: UTF8.self) == "123456", "serial matches the Mac's")
    check(HuaweiBandRecord.fromSharedKey("nope") == nil, "rejects junk")
}

group("notification layout matches controls.py") {
    let req = HuaweiControls.notification(id: 0x1234, title: "Claude", text: "done", sender: "claude")
    check(req.service == 0x02 && req.command == 0x01 && req.encrypted, "ids")
    let items = (try? HuaweiTLV.parse(try HuaweiTLV.parse(req.tlv.get(0x84)).get(0x8C)).getAll(0x8D)) ?? []
    let texts = items.compactMap { try? HuaweiTLV.parse($0).get(0x10) }.map { String(decoding: $0, as: UTF8.self) }
    check(texts == ["Claude", "claude", "done"], "texts \(texts)")
}

await runHandshakes()

if failures.isEmpty {
    print("all passed")
    exit(0)
}
print("\n\(failures.count) failure(s):")
for f in failures { print("  - \(f)") }
exit(1)
