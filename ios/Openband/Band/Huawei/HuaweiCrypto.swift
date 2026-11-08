import CommonCrypto
import CryptoKit
import Foundation

// Huawei link crypto: auth digests, bonding key, PIN decryption, payload encryption. The
// constants are the published values the Huawei link uses for every device (Gadgetbridge's
// HuaweiCrypto.java). Nothing here is per-user. Port of openband/crypto.py.

enum HuaweiCryptoError: Error, Equatable, CustomStringConvertible {
    case missingKey
    case badMAC(String)
    case badNonce(Int)
    case cipher(Int32)
    case gcm(String)

    var description: String {
        switch self {
        case .missingKey: return "HiChain Lite needs a key (PIN or secret key)"
        case .badMAC(let mac): return "not a MAC address: \(mac)"
        case .badNonce(let n): return "bad nonce length \(n)"
        case .cipher(let status): return "AES-CBC failed (\(status)); wrong key or bad padding"
        case .gcm(let message): return "AES-GCM failed: \(message)"
        }
    }
}

enum HuaweiCrypto {
    static let secretKey1V1 = Data([0x6F, 0x75, 0x6A, 0x79, 0x6D, 0x77, 0x71, 0x34, 0x63, 0x6C, 0x76, 0x39, 0x33, 0x37, 0x38, 0x79])
    static let secretKey2V1 = Data([0x62, 0x31, 0x30, 0x6A, 0x67, 0x66, 0x64, 0x39, 0x79, 0x37, 0x76, 0x73, 0x75, 0x64, 0x61, 0x39])
    static let secretKey1V23 = Data([0x55, 0x53, 0x86, 0xFC, 0x63, 0x20, 0x07, 0xAA, 0x86, 0x49, 0x35, 0x22, 0xB8, 0x6A, 0xE2, 0x5C])
    static let secretKey2V23 = Data([0x33, 0x07, 0x9B, 0xC5, 0x7A, 0x88, 0x6D, 0x3C, 0xF5, 0x61, 0x37, 0x09, 0x6F, 0x22, 0x80, 0x00])

    static let digestSecretV1 = Data([0x70, 0xFB, 0x6C, 0x24, 0x03, 0x5F, 0xDB, 0x55, 0x2F, 0x38, 0x89, 0x8A, 0xEE, 0xDE, 0x3F, 0x69])
    static let digestSecretV2 = Data([0x93, 0xAC, 0xDE, 0xF7, 0x6A, 0xCB, 0x09, 0x85, 0x7D, 0xBF, 0xE5, 0x26, 0x1A, 0xAB, 0xCD, 0x78])
    static let digestSecretV3 = Data([0x9C, 0x27, 0x63, 0xA9, 0xCC, 0xE1, 0x34, 0x76, 0x6D, 0xE3, 0xFF, 0x61, 0x18, 0x20, 0x05, 0x53])

    static let messageResponse = Data([0x01, 0x10])
    static let messageChallenge = Data([0x01, 0x00])
    static let messageChallengeV4 = Data([0x04, 0x00])

    static let counterMax: UInt32 = 0xFFFF_FFFF

    // Auth modes, as negotiated after LinkParams.
    static let authModeNormal = 0x00
    static let authModeHiChainLite = 0x02
    static let authModeHiChain3 = 0x04

    // MARK: primitives

    static func hmac(key: Data, message: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key)))
    }

    static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    static func randomBytes(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0 ..< count).map { _ in UInt8.random(in: 0 ... 255, using: &g) })
    }

    static func nonce16() -> Data { randomBytes(16) }

    private static func hexUpper(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }

    static func pbkdf2SHA256(password: Data, salt: Data, rounds: Int, length: Int) -> Data {
        var out = [UInt8](repeating: 0, count: length)
        let pw = [UInt8](password)
        let s = [UInt8](salt)
        let status = pw.withUnsafeBufferPointer { pwp in
            pwp.baseAddress!.withMemoryRebound(to: Int8.self, capacity: pw.count) { pwChars in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pwChars, pw.count, s, s.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &out, length)
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return Data(out)
    }

    // MARK: digests

    static func digestSecret(authVersion: Int) -> Data {
        switch authVersion {
        case 1, 4: return digestSecretV1  // 4: Honor Health devices
        case 2: return digestSecretV2
        default: return digestSecretV3
        }
    }

    private static func digest(authVersion: Int, message: Data, nonce: Data) -> Data {
        let step1 = hmac(key: digestSecret(authVersion: authVersion) + message, message: nonce)
        return hmac(key: step1, message: nonce) + step1
    }

    private static func digestHiChainLite(authVersion: Int, authAlgo: Int, message: Data, key: Data, nonce: Data) -> Data {
        let hashKey = sha256(Data(hexUpper(key).utf8))
        let secret = Data(zip(hashKey.prefix(16), digestSecret(authVersion: authVersion)).map { $0 ^ $1 })
        let toDigest = secret + message
        let step1: Data
        if authAlgo == 0x01 {
            step1 = pbkdf2SHA256(password: Data(hexUpper(toDigest).utf8), salt: Data(hexUpper(nonce).utf8), rounds: 1000, length: 32)
        } else {
            step1 = hmac(key: toDigest, message: nonce)
        }
        return hmac(key: step1, message: nonce) + step1
    }

    /// 64 bytes; the first 32 go on the wire, the first 16 are the "first key".
    private static func digestFor(message: Data, nonce: Data, authVersion: Int, authMode: Int, authAlgo: Int, key: Data?) throws -> Data {
        if authMode == authModeHiChainLite {
            guard let key else { throw HuaweiCryptoError.missingKey }
            if authVersion == 0x02 {
                let k = key + message
                var out = hmac(key: k, message: nonce) + k
                if out.count < 64 { out.append(Data(count: 64 - out.count)) }
                return out
            }
            return digestHiChainLite(authVersion: authVersion, authAlgo: authAlgo, message: message, key: key, nonce: nonce)
        }
        let msg = (message == messageChallenge && authVersion == 4) ? messageChallengeV4 : message
        return digest(authVersion: authVersion, message: msg, nonce: nonce)
    }

    static func digestChallenge(nonce: Data, authVersion: Int, authMode: Int, authAlgo: Int, key: Data?) throws -> Data {
        try digestFor(message: messageChallenge, nonce: nonce, authVersion: authVersion, authMode: authMode, authAlgo: authAlgo, key: key)
    }

    static func digestResponse(nonce: Data, authVersion: Int, authMode: Int, authAlgo: Int, key: Data?) throws -> Data {
        try digestFor(message: messageResponse, nonce: nonce, authVersion: authVersion, authMode: authMode, authAlgo: authAlgo, key: key)
    }

    /// Key that wraps our secret key in normal mode, derived from the band's Bluetooth MAC.
    static func macBondKey(bandMAC: String, authVersion: Int) throws -> Data {
        let (k1, k2) = authVersion == 1 ? (secretKey1V1, secretKey2V1) : (secretKey1V23, secretKey2V23)
        let macKey = Data((bandMAC.replacingOccurrences(of: ":", with: "").uppercased() + "0000").utf8)
        guard macKey.count == 16 else { throw HuaweiCryptoError.badMAC(bandMAC) }
        let mixed = Data(zip(k1, k2).map { ($0 << 4) ^ $1 })
        let mixedHash = sha256(mixed)
        let final = Data(zip(mixedHash, macKey).map { ($0 >> 6) ^ $1 })
        return sha256(final).prefix(16)
    }

    // MARK: symmetric

    static func encrypt(useGCM: Bool, data: Data, key: Data, iv: Data) throws -> Data {
        if useGCM {
            do {
                let box = try AES.GCM.seal(data, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: iv))
                return box.ciphertext + box.tag
            } catch {
                throw HuaweiCryptoError.gcm("\(error)")
            }
        }
        return try cbc(CCOperation(kCCEncrypt), data: data, key: key, iv: iv)
    }

    static func decrypt(useGCM: Bool, data: Data, key: Data, iv: Data) throws -> Data {
        if useGCM {
            guard data.count >= 16 else { throw HuaweiCryptoError.gcm("ciphertext shorter than the tag") }
            do {
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: data.dropLast(16), tag: data.suffix(16))
                return try AES.GCM.open(box, using: SymmetricKey(data: key))
            } catch {
                throw HuaweiCryptoError.gcm("\(error)")
            }
        }
        return try cbc(CCOperation(kCCDecrypt), data: data, key: key, iv: iv)
    }

    private static func cbc(_ op: CCOperation, data: Data, key: Data, iv: Data) throws -> Data {
        let input = [UInt8](data), k = [UInt8](key), v = [UInt8](iv)
        var out = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             k, k.count, v, input, input.count, &out, out.count, &moved)
        guard status == kCCSuccess else { throw HuaweiCryptoError.cipher(status) }
        return Data(out.prefix(moved))
    }

    /// 12 random bytes + the next 4-byte big-endian counter; returns (iv, new counter).
    static func nextIV(counter: UInt32) -> (iv: Data, counter: UInt32) {
        let next: UInt32 = counter >= counterMax ? 1 : counter + 1
        return (randomBytes(12) + huaweiBytesBE(Int(next), size: 4), next)
    }
}
