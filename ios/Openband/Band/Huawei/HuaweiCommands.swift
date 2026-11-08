import Foundation

// Request builders and response parsers for the commands Openband uses. Service 0x01 is device
// config (link, auth, bond, product info, time, battery); service 0x07 is fitness data (totals,
// per-minute samples, sleep). Port of openband/commands.py.

struct HuaweiCommandID: Hashable, CustomStringConvertible {
    var service: UInt8
    var command: UInt8

    var description: String { String(format: "%02x/%02x", service, command) }
}

struct HuaweiRequest {
    var service: UInt8
    var command: UInt8
    var tlv: HuaweiTLV
    var encrypted = true
    var expectsReply = true

    var id: HuaweiCommandID { HuaweiCommandID(service: service, command: command) }
}

struct HuaweiProductInfo: Equatable {
    var model: String
    var softwareVersion: String
    var hardwareVersion: String?
    var serialNumber: String?
    var deviceName: String?
}

struct HuaweiTotals: Equatable {
    var steps = 0
    var calories = 0
    var distanceMeters = 0
}

/// One minute of activity. Fields the band did not send are nil.
struct HuaweiMinuteSample: Equatable {
    var timestamp: Date
    var steps: Int?
    var kcal: Int?
    var distance: Int?
    var heartRate: Int?
    var spo2: Int?
    var restingHR: Int?
    /// Values under bitmap bits Openband does not know yet ("b1_01", "b2_04", ...).
    var unknown: [String: Int] = [:]

    init(timestamp: Date, steps: Int? = nil, kcal: Int? = nil, distance: Int? = nil, heartRate: Int? = nil,
         spo2: Int? = nil, restingHR: Int? = nil, unknown: [String: Int] = [:]) {
        self.timestamp = timestamp
        self.steps = steps
        self.kcal = kcal
        self.distance = distance
        self.heartRate = heartRate
        self.spo2 = spo2
        self.restingHR = restingHR
        self.unknown = unknown
    }

    var unixTime: Int { Int(timestamp.timeIntervalSince1970) }
}

struct HuaweiSleepSpan: Equatable {
    enum Kind: Equatable {
        case light, deep
        case unknown(Int)
    }

    var start: Date
    var end: Date
    var kind: Kind
    var rawType: Int

    var minutes: Int { Int(end.timeIntervalSince(start) / 60) }
}

enum HuaweiCommands {
    static let deviceConfig: UInt8 = 0x01
    static let fitness: UInt8 = 0x07

    // device config
    static let linkParamsID: UInt8 = 0x01
    static let supportedServicesID: UInt8 = 0x02
    static let timeID: UInt8 = 0x05
    static let productInfoID: UInt8 = 0x07
    static let batteryID: UInt8 = 0x08
    static let bondID: UInt8 = 0x0E
    static let bondParamsID: UInt8 = 0x0F
    static let authID: UInt8 = 0x13
    static let batteryChangedID: UInt8 = 0x27
    static let pinCodeID: UInt8 = 0x2C
    static let securityNegotiationID: UInt8 = 0x33

    // fitness
    static let fitnessTotalsID: UInt8 = 0x03
    static let stepCountID: UInt8 = 0x0A
    static let stepDataID: UInt8 = 0x0B
    static let sleepCountID: UInt8 = 0x0C
    static let sleepDataID: UInt8 = 0x0D

    static let hiChainFull = 0x0186A0

    // MARK: link and auth (never encrypted)

    static func linkParams() -> HuaweiRequest {
        HuaweiRequest(service: deviceConfig, command: linkParamsID,
                      tlv: HuaweiTLV().put(0x01).put(0x02).put(0x03).put(0x04), encrypted: false)
    }

    static func securityNegotiation(authMode: Int, deviceUUID: Data, encryptMethod: Int, phoneModel: String = "iPhone") -> HuaweiRequest {
        var t = HuaweiTLV().put(0x01, byte: authMode)
        if authMode == 0x02 || authMode == 0x04 {
            t = t.put(0x02, byte: 0x01)  // 1: fresh pairing, not a reconnect
        }
        t = t.put(0x05, deviceUUID).put(0x03, byte: 0x01).put(0x04, byte: 0x00)
        if authMode == 0x04 {
            t = t.put(0x06).put(0x07, string: phoneModel)
        }
        if encryptMethod == 0x01 {
            t = t.put(0x0D, byte: 0x01)
        }
        return HuaweiRequest(service: deviceConfig, command: securityNegotiationID, tlv: t, encrypted: false)
    }

    /// The negotiated auth type: 1 or 2 mean HiChain Lite, 0x186A0 or HiChain3 mean full HiChain.
    static func parseSecurityNegotiation(_ t: HuaweiTLV) -> Int {
        var authType = -1
        var pw = -1
        if t.contains(0x01) {
            let b = t.byte(0x01, default: -1)
            if b == 0x01 { authType = hiChainFull }
            if b == 0x04 { pw = 4 }
        }
        if t.contains(0x02) {
            authType = t.byte(0x02, default: -1)
            if pw != -1 { authType ^= pw }
        }
        if t.contains(0x7F), let first = t.get(0x7F, default: Data()).first {
            authType = Int(first)
        }
        return authType
    }

    static func isHiChain3(_ authType: Int) -> Bool {
        (authType ^ 0x01) == 0x04 || (authType ^ 0x02) == 0x04
    }

    static func pinCode() -> HuaweiRequest {
        HuaweiRequest(service: deviceConfig, command: pinCodeID, tlv: HuaweiTLV().put(0x01), encrypted: false)
    }

    static func auth(challenge: Data, authVersion: Int, clientNonce: Data, authMode: Int, authAlgo: Int) -> HuaweiRequest {
        var t = HuaweiTLV().put(0x01, challenge).put(0x02, huaweiBytesBE(authVersion, size: 2) + clientNonce)
        if authMode == 0x02 { t = t.put(0x03, byte: authAlgo) }
        return HuaweiRequest(service: deviceConfig, command: authID, tlv: t, encrypted: false)
    }

    static func bondParams(clientSerial: Data, clientMAC: Data) -> HuaweiRequest {
        let t = HuaweiTLV().put(0x01).put(0x03, clientSerial).put(0x04, byte: 0x02).put(0x05).put(0x07, clientMAC).put(0x09)
        return HuaweiRequest(service: deviceConfig, command: bondParamsID, tlv: t, encrypted: false)
    }

    static func bond(clientSerial: Data, wrappedKey: Data, iv: Data) -> HuaweiRequest {
        let t = HuaweiTLV().put(0x01).put(0x03, byte: 0x00).put(0x05, clientSerial).put(0x06, wrappedKey).put(0x07, iv)
        return HuaweiRequest(service: deviceConfig, command: bondID, tlv: t, encrypted: false)
    }

    // MARK: device config after auth

    static let knownServices: [UInt8] = [
        0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
        0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x1B, 0x1D, 0x20, 0x22, 0x23,
        0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x30, 0x32, 0x33, 0x34, 0x35,
    ]

    static func supportedServices() -> HuaweiRequest {
        HuaweiRequest(service: deviceConfig, command: supportedServicesID, tlv: HuaweiTLV().put(0x01, knownServices))
    }

    static func parseSupportedServices(_ t: HuaweiTLV) -> [UInt8] {
        let flags = t.get(0x02, default: Data())
        return zip(knownServices, flags).filter { $0.1 != 0 }.map(\.0)
    }

    static func productInfo() -> HuaweiRequest {
        var t = HuaweiTLV()
        for tag: UInt8 in [0x01, 0x02, 0x07, 0x09, 0x0A, 0x11, 0x12, 0x16, 0x1A, 0x1D, 0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23] {
            t = t.put(tag)
        }
        return HuaweiRequest(service: deviceConfig, command: productInfoID, tlv: t)
    }

    static func parseProductInfo(_ t: HuaweiTLV) -> HuaweiProductInfo {
        func opt(_ tag: UInt8) -> String? { t.contains(tag) ? t.string(tag, default: "") : nil }
        return HuaweiProductInfo(model: t.string(0x0A, default: "").trimmingCharacters(in: .whitespaces),
                                 softwareVersion: t.string(0x07, default: ""),
                                 hardwareVersion: opt(0x03), serialNumber: opt(0x09), deviceName: opt(0x11))
    }

    /// (unix seconds, packed zone) with the band's encoding: hours byte (+128 when west of UTC)
    /// and a minutes byte that keeps Java's sign on negative half-hour zones.
    static func timeAndZone(_ now: Date, timeZone: TimeZone = .current) -> (unix: Int, zone: Int) {
        let offset = timeZone.secondsFromGMT(for: now)
        let hours = offset < 0 ? (-offset / 3600 + 128) : offset / 3600
        let totalMinutes = offset / 60  // truncates toward zero, like Python's int(offset / 60)
        let minutes = totalMinutes - (totalMinutes / 60) * 60
        return (Int(now.timeIntervalSince1970.rounded(.down)), ((hours & 0xFF) << 8) | (minutes & 0xFF))
    }

    static func setTime(_ now: Date = Date(), timeZone: TimeZone = .current) -> HuaweiRequest {
        let (unix, zone) = timeAndZone(now, timeZone: timeZone)
        return HuaweiRequest(service: deviceConfig, command: timeID, tlv: HuaweiTLV().put(0x01, u32: unix).put(0x02, u16: zone))
    }

    static func battery() -> HuaweiRequest {
        HuaweiRequest(service: deviceConfig, command: batteryID, tlv: HuaweiTLV().put(0x01))
    }

    static func parseBattery(_ t: HuaweiTLV) throws -> Int { try t.byte(0x01) }

    // MARK: fitness

    static func fitnessTotals() -> HuaweiRequest {
        HuaweiRequest(service: fitness, command: fitnessTotalsID, tlv: HuaweiTLV().put(0x01))
    }

    static func parseFitnessTotals(_ t: HuaweiTLV) throws -> HuaweiTotals {
        var out = HuaweiTotals()
        for c in try t.child(0x81).children(0x83) {
            out.steps += c.uint(0x05, default: 0)
            out.calories += c.uint(0x06, default: 0)
            out.distanceMeters += c.uint(0x07, default: 0)
        }
        return out
    }

    static func messageCount(command: UInt8, start: Int, end: Int) -> HuaweiRequest {
        HuaweiRequest(service: fitness, command: command, tlv: HuaweiTLV().put(0x81).put(0x03, u32: start).put(0x04, u32: end))
    }

    static func parseMessageCount(_ t: HuaweiTLV) throws -> Int { try t.child(0x81).uint(0x02) }

    static func messageData(command: UInt8, index: Int) -> HuaweiRequest {
        HuaweiRequest(service: fitness, command: command, tlv: HuaweiTLV().put(0x81, tlv: HuaweiTLV().put(0x02, u16: index)))
    }

    /// A feature bitmap, an optional second bitmap (when bit 0x80 is set), then the values.
    static func parseMinute(timestamp: Int, data: Data) throws -> HuaweiMinuteSample {
        var s = HuaweiMinuteSample(timestamp: Date(timeIntervalSince1970: TimeInterval(timestamp)))
        let d = [UInt8](data)
        guard !d.isEmpty else { throw HuaweiError.unexpected("minute record without a feature bitmap") }
        var i = 0
        let bm1 = d[i]
        i += 1
        var bm2: UInt8 = 0
        if bm1 & 0x80 != 0 {
            guard i < d.count else { throw HuaweiError.unexpected("minute record too short for its second bitmap: \(huaweiHex(data))") }
            bm2 = d[i]
            i += 1
        }
        var bit: UInt8 = 1
        while bit < 0x80 {
            if bm1 & bit != 0 {
                let width = (bit == 0x20 || bit == 0x40) ? 1 : 2
                guard i + width <= d.count else {
                    throw HuaweiError.unexpected(String(format: "minute record too short for bitmap %02x: ", bm1) + huaweiHex(data))
                }
                let value = d[i ..< i + width].reduce(0) { ($0 << 8) | Int($1) }
                i += width
                switch bit {
                case 0x02: s.steps = value
                case 0x04: s.kcal = value
                case 0x08: s.distance = value
                case 0x40: s.heartRate = value
                default: s.unknown[String(format: "b1_%02x", bit)] = value
                }
            }
            bit <<= 1
        }
        var bit2 = 1
        while bit2 < 0x100 {
            if Int(bm2) & bit2 != 0 {
                guard i < d.count else {
                    throw HuaweiError.unexpected(String(format: "minute record too short for bitmap2 %02x: ", bm2) + huaweiHex(data))
                }
                let value = Int(d[i])
                i += 1
                switch bit2 {
                case 0x01: s.spo2 = value
                case 0x02: s.restingHR = value
                default: s.unknown[String(format: "b2_%02x", bit2)] = value
                }
            }
            bit2 <<= 1
        }
        return s
    }

    /// The record number, its samples, and a note for each minute that could not be read
    /// (skipped, like the Python version does with a warning).
    static func parseStepData(_ t: HuaweiTLV) throws -> (number: Int, samples: [HuaweiMinuteSample], problems: [String]) {
        let c = try t.child(0x81)
        let number = try c.uint(0x02)
        let base = try c.uint(0x03)
        var out: [HuaweiMinuteSample] = []
        var problems: [String] = []
        for sub in try c.children(0x84) {
            let offset = sub.byte(0x05, default: 0)
            let ts = base + 60 * offset
            do {
                out.append(try parseMinute(timestamp: ts, data: sub.get(0x06, default: Data())))
            } catch {
                problems.append("skipping minute at \(ts): \(error)")
            }
        }
        return (number, out, problems)
    }

    static let sleepLight = 0x06
    static let sleepDeep = 0x07

    static func parseSleepData(_ t: HuaweiTLV) throws -> (number: Int, spans: [HuaweiSleepSpan]) {
        let c = try t.child(0x81)
        let number = try c.uint(0x02)
        var out: [HuaweiSleepSpan] = []
        for sub in try c.children(0x83) {
            let type = try sub.byte(0x04)
            let ts = [UInt8](try sub.get(0x05))
            guard ts.count >= 6 else { throw HuaweiError.unexpected("sleep span too short: \(huaweiHex(Data(ts)))") }
            let start = ts[0 ..< 4].reduce(0) { ($0 << 8) | Int($1) }
            let minutes = ts[4 ..< 6].reduce(0) { ($0 << 8) | Int($1) }
            let kind: HuaweiSleepSpan.Kind = type == sleepLight ? .light : (type == sleepDeep ? .deep : .unknown(type))
            out.append(HuaweiSleepSpan(start: Date(timeIntervalSince1970: TimeInterval(start)),
                                       end: Date(timeIntervalSince1970: TimeInterval(start + minutes * 60)),
                                       kind: kind, rawType: type))
        }
        return (number, out)
    }
}
