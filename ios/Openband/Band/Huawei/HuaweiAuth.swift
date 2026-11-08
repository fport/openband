import Foundation

// The handshake: LinkParams, (security negotiation, PIN), Auth, BondParams, Bond.
//
// Two paths, picked by what the band reports in LinkParams:
// * normal mode (support type 0 or 8, the Band 6): the challenge uses a fixed digest secret, and
//   the bond wraps our key with a key derived from the band's Bluetooth MAC.
// * HiChain Lite (support type 1-4, negotiated auth type 1 or 2): the challenge is keyed with a
//   PIN the band hands over (or our secret key on auth version 2), and the bond wraps our key
//   with the first 16 bytes of that challenge.
// Full HiChain (SPEKE) is not implemented; we stop with a clear error if a band asks for it.
// Port of openband/auth.py.

/// What Openband remembers per band: our session key and the identity we present to it.
struct HuaweiBandRecord: Codable, Equatable {
    /// 16 bytes, ours, handed to the band when bonding.
    var secretKey: Data
    /// A made-up MAC we introduce ourselves with.
    var clientMAC: String
    /// A made-up phone id for security negotiation (32 hex characters).
    var deviceUUID: String
    /// The band's own Bluetooth MAC; only normal-mode bonding needs it.
    var bandMAC: String?
    var bonded: Bool

    static func new(bandMAC: String? = nil) -> HuaweiBandRecord {
        let tail = HuaweiCrypto.randomBytes(3).map { String(format: "%02X", $0) }.joined(separator: ":")
        return HuaweiBandRecord(secretKey: HuaweiCrypto.randomBytes(16), clientMAC: "FF:FF:FF:" + tail,
                                deviceUUID: HuaweiCrypto.randomBytes(16).map { String(format: "%02X", $0) }.joined(),
                                bandMAC: bandMAC, bonded: false)
    }

    /// The last six hex digits of our made-up MAC, as ASCII.
    var clientSerial: Data {
        let hex = Array(clientMAC.replacingOccurrences(of: ":", with: ""))
        return Data(String(hex[min(6, hex.count) ..< min(12, hex.count)]).utf8)
    }
}

extension HuaweiBandRecord {
    /// The line `openband key` prints on the Mac:
    /// `openband-key:v1:<secret hex>:<client MAC>:<device uuid>:<band MAC>`. The band already knows
    /// that key, so a phone using it needs no pairing of its own and the Mac keeps working.
    static func fromSharedKey(_ text: String) -> HuaweiBandRecord? {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("openband-key:v1:") else { return nil }
        let rest = String(line.dropFirst("openband-key:v1:".count))
        // The MACs contain ':', so split the fixed-width fields by position.
        guard rest.count >= 32 + 1 + 17 + 1 + 32 else { return nil }
        let secretHex = String(rest.prefix(32))
        var cursor = rest.index(rest.startIndex, offsetBy: 33)
        let clientMAC = String(rest[cursor ..< rest.index(cursor, offsetBy: 17)])
        cursor = rest.index(cursor, offsetBy: 18)
        let deviceUUID = String(rest[cursor ..< rest.index(cursor, offsetBy: 32)])
        cursor = rest.index(cursor, offsetBy: 32)
        let bandMAC = cursor < rest.endIndex ? String(rest[rest.index(after: cursor)...]) : ""
        guard let secret = huaweiData(hex: secretHex), secret.count == 16 else { return nil }
        return HuaweiBandRecord(secretKey: secret, clientMAC: clientMAC.uppercased(), deviceUUID: deviceUUID.uppercased(),
                                bandMAC: bandMAC.isEmpty ? nil : bandMAC.uppercased(), bonded: true)
    }
}

struct HuaweiAuthReport: Equatable {
    var params: HuaweiLinkParams
    var authMode: Int
    var negotiatedAuthType: Int?
    var bondStatus: Int?
    var bondedNow: Bool
}

@MainActor
func huaweiReadLinkParams(_ channel: HuaweiChannel) async throws -> HuaweiLinkParams {
    let t = try await channel.request(HuaweiCommands.linkParams())
    let params = try HuaweiLinkParams(tlv: t)
    channel.session.params = params
    return params
}

/// Runs the whole handshake. With allowBond false we refuse to write a new key to the band.
@MainActor
func huaweiAuthenticate(_ channel: HuaweiChannel, record: HuaweiBandRecord, allowBond: Bool) async throws -> HuaweiAuthReport {
    let s = channel.session
    let params = try await huaweiReadLinkParams(channel)
    s.secretKey = record.secretKey
    var negotiated: Int?

    if params.usesHiChain {
        s.authMode = params.deviceSupportType == 0x04 ? HuaweiCrypto.authModeHiChain3 : HuaweiCrypto.authModeHiChainLite
        let t = try await channel.request(HuaweiCommands.securityNegotiation(
            authMode: s.authMode, deviceUUID: Data(record.deviceUUID.utf8), encryptMethod: params.encryptMethod))
        let type = HuaweiCommands.parseSecurityNegotiation(t)
        negotiated = type
        channel.onLog?("security negotiation: auth type \(type) (\(t))")
        if type == HuaweiCommands.hiChainFull || HuaweiCommands.isHiChain3(type) {
            throw HuaweiError.hiChainUnsupported(type)
        }
        guard type == 0x01 || type == 0x02 else {
            throw HuaweiError.unexpected("unexpected security negotiation answer: \(t)")
        }
        s.authMode = HuaweiCrypto.authModeHiChainLite
    } else {
        s.authMode = HuaweiCrypto.authModeNormal
    }

    // Challenge key: HiChain Lite uses the band's PIN, or our own key on auth version 2.
    var key: Data?
    if s.authMode == HuaweiCrypto.authModeHiChainLite {
        if params.authVersion == 0x02 {
            key = record.secretKey
        } else {
            let t = try await channel.request(HuaweiCommands.pinCode())
            key = try HuaweiCrypto.decrypt(useGCM: params.encryptMethod == 0x01, data: try t.get(0x01),
                                           key: HuaweiCrypto.digestSecret(authVersion: params.authVersion), iv: try t.get(0x02))
            channel.onLog?("got the band's PIN")
        }
    }

    let clientNonce = HuaweiCrypto.nonce16()
    let doubleNonce = params.serverNonce + clientNonce
    let challenge = try HuaweiCrypto.digestChallenge(nonce: doubleNonce, authVersion: params.authVersion, authMode: s.authMode,
                                                     authAlgo: params.authAlgo, key: key)
    let firstKey = challenge.prefix(16)
    let answer = try await channel.request(HuaweiCommands.auth(challenge: challenge.prefix(32), authVersion: params.authVersion,
                                                               clientNonce: clientNonce, authMode: s.authMode,
                                                               authAlgo: params.authAlgo))
    let expected = try HuaweiCrypto.digestResponse(nonce: doubleNonce, authVersion: params.authVersion, authMode: s.authMode,
                                                   authAlgo: params.authAlgo, key: key).prefix(32)
    guard huaweiConstantTimeEqual(answer.get(0x01, default: Data()), Data(expected)) else { throw HuaweiError.badChallenge }
    channel.onLog?("challenge passed")

    let bp = try await channel.request(HuaweiCommands.bondParams(clientSerial: record.clientSerial,
                                                                 clientMAC: Data(record.clientMAC.utf8)))
    let bondStatus = bp.byte(0x01, default: 0)
    s.counter = UInt32(truncatingIfNeeded: bp.uint(0x09, default: 0))

    let skipBond = s.authMode == HuaweiCrypto.authModeNormal && bondStatus == 1 && record.bonded
    var bondedNow = false
    if !skipBond {
        if !record.bonded && !allowBond {
            throw HuaweiError.needsBond("this band has not been paired with Openband yet")
        }
        let wrapKey: Data
        if s.authMode == HuaweiCrypto.authModeHiChainLite {
            wrapKey = Data(firstKey)
        } else {
            guard let mac = record.bandMAC, !mac.isEmpty else { throw HuaweiError.needsBandMAC }
            wrapKey = try HuaweiCrypto.macBondKey(bandMAC: mac, authVersion: params.authVersion)
        }
        let iv = s.iv()
        let wrapped = try HuaweiCrypto.encrypt(useGCM: params.encryptMethod == 0x01, data: record.secretKey, key: wrapKey, iv: iv)
        do {
            _ = try await channel.request(HuaweiCommands.bond(clientSerial: record.clientSerial, wrappedKey: wrapped, iv: iv),
                                          timeout: min(5, channel.defaultTimeout))
        } catch let error as HuaweiError {
            switch error {
            case .timeout, .refused:
                // Some bands do not answer the bond message; the next encrypted request tells.
                channel.onLog?("no answer to bond (\(error)); carrying on")
            default:
                throw error
            }
        }
        bondedNow = !record.bonded
    }
    s.authenticated = true
    return HuaweiAuthReport(params: params, authMode: s.authMode, negotiatedAuthType: negotiated, bondStatus: bondStatus,
                            bondedNow: bondedNow)
}

func huaweiConstantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
}
