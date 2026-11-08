import Foundation

// A simulated Huawei band: the band side of the handshake and a few data commands. It answers
// in 20-byte notifications so the channel's reassembly gets exercised too. Port of
// tests/fake_band.py.

struct BandConfig {
    var supportType = 0x02
    var authVersion = 0x03
    var authAlgo = 0x00
    var encryptMethod = 0x00
    var negotiatedAuthType = 0x02
    var pin = Data("482913".utf8)
    var mac = "A4:C1:38:5D:7E:9F"
    var counter: UInt32 = 0x100
    var bondStatus = 0
    var answerBond = true
}

struct FakeBandError: Error, CustomStringConvertible {
    let description: String
}

@MainActor
class FakeBand {
    var cfg: BandConfig
    /// Only for HiChain Lite v2, where the challenge uses our key.
    var clientKey: Data?
    var sessionKey: Data?
    var counter: UInt32 = 0
    var seen: [HuaweiCommandID] = []
    var stepsRecords: [HuaweiTLV] = []
    var sleepRecords: [HuaweiTLV] = []
    weak var channel: HuaweiChannel?

    let maxWrite = 244
    private let serverNonce = Data(repeating: 0x5A, count: 16)
    private var firstKey = Data()
    private var reassembler = HuaweiReassembler()

    init(_ cfg: BandConfig = BandConfig(), clientKey: Data? = nil, sessionKey: Data? = nil) {
        self.cfg = cfg
        self.clientKey = clientKey
        self.sessionKey = sessionKey
    }

    /// A channel wired to this band.
    func connect(timeout: TimeInterval = 2) -> HuaweiChannel {
        let channel = HuaweiChannel(session: HuaweiSession(), maxWrite: maxWrite, write: { data in
            try self.write(data)
        }, defaultTimeout: timeout)
        self.channel = channel
        return channel
    }

    // MARK: transport side

    func write(_ data: Data) throws {
        for m in try reassembler.feed(data) {
            let id = HuaweiCommandID(service: m.service, command: m.command)
            seen.append(id)
            guard let (encrypted, reply) = try handle(id, try HuaweiTLV.parse(m.body)) else { continue }
            let body = encrypted ? try seal(reply) : reply
            let stream = try HuaweiFrame.encode(service: m.service, command: m.command, body: body.serialize()).reduce(Data(), +)
            var chunks: [Data] = []
            var i = 0
            while i < stream.count {
                chunks.append(stream.subdata(in: i ..< min(i + 20, stream.count)))
                i += 20
            }
            let channel = self.channel
            let packets = chunks
            Task { @MainActor in
                for c in packets { channel?.receive(c) }
            }
        }
    }

    // MARK: crypto

    var gcm: Bool { cfg.encryptMethod == 1 || cfg.supportType == 4 }

    private func seal(_ body: HuaweiTLV) throws -> HuaweiTLV {
        let next = HuaweiCrypto.nextIV(counter: counter)
        counter = next.counter
        let ct = try HuaweiCrypto.encrypt(useGCM: gcm, data: body.serialize(), key: sessionKey!, iv: next.iv)
        return HuaweiTLV().put(HuaweiSession.tagEncrypted, byte: 1).put(HuaweiSession.tagIV, next.iv).put(HuaweiSession.tagCiphertext, ct)
    }

    private func open(_ t: HuaweiTLV) throws -> HuaweiTLV {
        guard t.contains(HuaweiSession.tagEncrypted) else { throw FakeBandError(description: "expected an encrypted request") }
        return try HuaweiTLV.parse(try HuaweiCrypto.decrypt(useGCM: gcm, data: t.get(HuaweiSession.tagCiphertext),
                                                             key: sessionKey!, iv: t.get(HuaweiSession.tagIV)))
    }

    var authMode: Int { (1 ... 4).contains(cfg.supportType) ? HuaweiCrypto.authModeHiChainLite : HuaweiCrypto.authModeNormal }

    private var challengeKey: Data? {
        guard authMode == HuaweiCrypto.authModeHiChainLite else { return nil }
        return cfg.authVersion == 2 ? clientKey : cfg.pin
    }

    private func challenge(_ nonce: Data) throws -> Data {
        try HuaweiCrypto.digestChallenge(nonce: nonce, authVersion: cfg.authVersion, authMode: authMode, authAlgo: cfg.authAlgo, key: challengeKey)
    }

    private func response(_ nonce: Data) throws -> Data {
        try HuaweiCrypto.digestResponse(nonce: nonce, authVersion: cfg.authVersion, authMode: authMode, authAlgo: cfg.authAlgo, key: challengeKey)
    }

    // MARK: protocol

    /// (encrypt the answer?, answer); nil sends nothing back.
    func handle(_ id: HuaweiCommandID, _ t: HuaweiTLV) throws -> (Bool, HuaweiTLV)? {
        let c = cfg
        typealias C = HuaweiCommands
        switch (id.service, id.command) {
        case (1, C.linkParamsID):
            return (false, HuaweiTLV()
                .put(0x01, byte: 2).put(0x02, u16: 0xF4).put(0x03, u16: 0x200).put(0x04, u16: 0)
                .put(0x05, Data([0, UInt8(c.authVersion)]) + serverNonce)
                .put(0x07, byte: c.supportType).put(0x08, byte: c.authAlgo)
                .put(0x09, byte: 0).put(0x0C, byte: c.encryptMethod))
        case (1, C.securityNegotiationID):
            return (false, HuaweiTLV().put(0x02, byte: c.negotiatedAuthType))
        case (1, C.pinCodeID):
            let iv = Data(repeating: 0x11, count: c.encryptMethod == 1 ? 12 : 16)
            let ct = try HuaweiCrypto.encrypt(useGCM: c.encryptMethod == 1, data: c.pin,
                                              key: HuaweiCrypto.digestSecret(authVersion: c.authVersion), iv: iv)
            return (false, HuaweiTLV().put(0x01, ct).put(0x02, iv))
        case (1, C.authID):
            let nonce = serverNonce + (try t.get(0x02)).dropFirst(2)
            let chal = try challenge(nonce)
            guard try t.get(0x01) == chal.prefix(32) else {
                return (false, HuaweiTLV().put(HuaweiSession.tagResult, u32: 0x0001_0001))
            }
            firstKey = Data(chal.prefix(16))
            return (false, HuaweiTLV().put(0x01, Data(try response(nonce).prefix(32))))
        case (1, C.bondParamsID):
            counter = c.counter
            return (false, HuaweiTLV().put(0x01, byte: c.bondStatus).put(0x09, u32: Int(c.counter)))
        case (1, C.bondID):
            let wrap = authMode == HuaweiCrypto.authModeHiChainLite ? firstKey : try HuaweiCrypto.macBondKey(bandMAC: c.mac, authVersion: c.authVersion)
            let iv = try t.get(0x07)
            sessionKey = try HuaweiCrypto.decrypt(useGCM: c.encryptMethod == 1, data: try t.get(0x06), key: wrap, iv: iv)
            counter = UInt32(huaweiBigEndian(iv.suffix(4)))
            return c.answerBond ? (false, HuaweiTLV().put(HuaweiSession.tagResult, u32: 100_000)) : nil
        default:
            break
        }

        let req = try open(t)
        switch (id.service, id.command) {
        case (1, C.productInfoID):
            return (true, HuaweiTLV().put(0x07, string: "1.0.1.36").put(0x0A, string: "FRA-B19 ").put(0x09, string: "SN123"))
        case (1, C.batteryID):
            return (true, HuaweiTLV().put(0x01, byte: 77))
        case (1, C.timeID):
            guard req.contains(0x01), req.contains(0x02) else { throw FakeBandError(description: "time without fields") }
            return (true, HuaweiTLV().put(HuaweiSession.tagResult, u32: 100_000))
        case (7, C.fitnessTotalsID):
            let day = HuaweiTLV().put(0x05, u32: 1234).put(0x06, u16: 56).put(0x07, u32: 900)
            return (true, HuaweiTLV().put(0x81, tlv: HuaweiTLV().put(0x83, tlv: day)))
        case (7, C.stepCountID):
            return (true, HuaweiTLV().put(0x81, tlv: HuaweiTLV().put(0x02, u16: stepsRecords.count)))
        case (7, C.stepDataID):
            return (true, stepsRecords[try req.child(0x81).uint(0x02)])
        case (7, C.sleepCountID):
            if sleepRecords.isEmpty { return (true, HuaweiTLV().put(HuaweiSession.tagResult, u32: 0x0001_E079)) }
            return (true, HuaweiTLV().put(0x81, tlv: HuaweiTLV().put(0x02, u16: sleepRecords.count)))
        case (7, C.sleepDataID):
            return (true, sleepRecords[try req.child(0x81).uint(0x02)])
        default:
            throw FakeBandError(description: "fake band got unexpected \(id)")
        }
    }
}
