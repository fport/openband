import Foundation

// Per-connection state: what LinkParams told us, the session key and the IV counter.
// Port of openband/session.py.

struct HuaweiLinkParams: Equatable {
    var protocolVersion = 0
    var sliceSize = HuaweiFrame.defaultSliceSize
    var mtu = 0x14
    var interval = 0
    var authVersion = 0
    var serverNonce = Data()
    var deviceSupportType = 0
    var authAlgo = 0
    var bondState = 0
    var encryptMethod = 0

    init() {}

    init(tlv t: HuaweiTLV) throws {
        let nonceField = try t.get(0x05)
        guard nonceField.count >= 18 else {
            throw HuaweiError.unexpected("LinkParams nonce field too short: \(huaweiHex(nonceField))")
        }
        let n = [UInt8](nonceField)
        protocolVersion = t.byte(0x01, default: 0)
        sliceSize = t.uint(0x02, default: HuaweiFrame.defaultSliceSize)
        mtu = t.uint(0x03, default: 0x14)
        interval = t.uint(0x04, default: 0)
        authVersion = Int(n[1])
        serverNonce = Data(n[2 ..< 18])
        deviceSupportType = t.byte(0x07, default: 0)
        authAlgo = t.byte(0x08, default: 0)
        bondState = t.byte(0x09, default: 0)
        encryptMethod = t.byte(0x0C, default: 0)
    }

    /// Support types 1-4 go through security negotiation first; 0 (and 8, the Band 6) use the
    /// plain "normal" mode.
    var usesHiChain: Bool { (1 ... 4).contains(deviceSupportType) }

    var path: String { usesHiChain ? "hichain" : "normal" }
}

final class HuaweiSession {
    static let tagEncrypted: UInt8 = 0x7C
    static let tagIV: UInt8 = 0x7D
    static let tagCiphertext: UInt8 = 0x7E
    static let tagResult: UInt8 = 0x7F
    static let resultSuccess = 100_000

    var params = HuaweiLinkParams()
    var secretKey: Data?
    var counter: UInt32 = 0
    var authMode = HuaweiCrypto.authModeNormal
    var authenticated = false

    init() {}

    var useGCM: Bool { params.encryptMethod == 0x01 || params.deviceSupportType == 0x04 }

    func iv() -> Data {
        if params.deviceSupportType == 0x04 { return HuaweiCrypto.randomBytes(16) }
        let next = HuaweiCrypto.nextIV(counter: counter)
        counter = next.counter
        return next.iv
    }

    func seal(_ body: HuaweiTLV) throws -> HuaweiTLV {
        guard let key = secretKey else { throw HuaweiError.noSessionKey }
        let iv = iv()
        let ct = try HuaweiCrypto.encrypt(useGCM: useGCM, data: body.serialize(), key: key, iv: iv)
        return HuaweiTLV().put(Self.tagEncrypted, byte: 0x01).put(Self.tagIV, iv).put(Self.tagCiphertext, ct)
    }

    func open(_ body: HuaweiTLV) throws -> HuaweiTLV {
        guard body.contains(Self.tagEncrypted), body.byte(Self.tagEncrypted, default: 0) == 1 else { return body }
        guard let key = secretKey else { throw HuaweiError.noSessionKey }
        let plain = try HuaweiCrypto.decrypt(useGCM: useGCM, data: try body.get(Self.tagCiphertext), key: key,
                                             iv: try body.get(Self.tagIV))
        return try HuaweiTLV.parse(plain)
    }
}
