import Foundation

// Huawei TLV: one-byte tag, big-endian base-128 varint length, value. Tags with the high bit set
// (0x80 and up) hold nested TLVs. Integers are big-endian. Port of openband/tlv.py.

enum HuaweiTLVError: Error, Equatable, CustomStringConvertible {
    case missingTag(UInt8)
    case truncatedVarint
    case truncated(tag: UInt8, claimed: Int, left: Int)
    case emptyValue(UInt8)

    var description: String {
        switch self {
        case .missingTag(let tag): return String(format: "missing tag 0x%02x", tag)
        case .truncatedVarint: return "truncated varint"
        case let .truncated(tag, claimed, left): return String(format: "tag 0x%02x claims %d bytes, %d left", tag, claimed, left)
        case .emptyValue(let tag): return String(format: "tag 0x%02x has no value", tag)
        }
    }
}

/// Big-endian base-128: the high bit marks "more bytes follow" (not protobuf order).
func huaweiEncodeVarint(_ value: Int) -> Data {
    precondition(value >= 0, "varint must be non-negative")
    var v = value
    var groups: [UInt8] = [UInt8(v & 0x7F)]
    v >>= 7
    while v > 0 {
        groups.append(UInt8(v & 0x7F) | 0x80)
        v >>= 7
    }
    return Data(groups.reversed())
}

/// Returns (value, bytes consumed).
func huaweiDecodeVarint(_ buf: [UInt8], at offset: Int) throws -> (value: Int, used: Int) {
    var value = 0
    var i = offset
    while true {
        guard i < buf.count else { throw HuaweiTLVError.truncatedVarint }
        let b = buf[i]
        i += 1
        value = (value << 7) | Int(b & 0x7F)
        if b & 0x80 == 0 { return (value, i - offset) }
    }
}

/// Big-endian unsigned int of whatever width (up to 8 bytes).
func huaweiBigEndian(_ data: Data) -> Int {
    data.reduce(0) { ($0 << 8) | Int($1) }
}

func huaweiBytesBE(_ value: Int, size: Int) -> Data {
    Data((0 ..< size).map { i in UInt8(truncatingIfNeeded: value >> (8 * (size - 1 - i))) })
}

struct HuaweiTLV: Equatable, CustomStringConvertible {
    struct Item: Equatable {
        var tag: UInt8
        var value: Data
    }

    var items: [Item] = []

    init() {}
    init(items: [Item]) { self.items = items }

    // MARK: building (each returns a copy, so calls chain: HuaweiTLV().put(0x01).put(0x02, byte: 1))

    func put(_ tag: UInt8, _ value: Data = Data()) -> HuaweiTLV {
        var copy = self
        copy.items.append(Item(tag: tag, value: Data(value)))
        return copy
    }

    func put(_ tag: UInt8, _ value: [UInt8]) -> HuaweiTLV { put(tag, Data(value)) }
    func put(_ tag: UInt8, byte value: Int) -> HuaweiTLV { put(tag, huaweiBytesBE(value, size: 1)) }
    func put(_ tag: UInt8, u16 value: Int) -> HuaweiTLV { put(tag, huaweiBytesBE(value, size: 2)) }
    func put(_ tag: UInt8, u32 value: Int) -> HuaweiTLV { put(tag, huaweiBytesBE(value, size: 4)) }
    func put(_ tag: UInt8, bool value: Bool) -> HuaweiTLV { put(tag, Data([value ? 1 : 0])) }
    func put(_ tag: UInt8, string value: String) -> HuaweiTLV { put(tag, Data(value.utf8)) }
    func put(_ tag: UInt8, tlv value: HuaweiTLV) -> HuaweiTLV { put(tag, value.serialize()) }

    func serialize() -> Data {
        var out = Data()
        for item in items {
            out.append(item.tag)
            out.append(huaweiEncodeVarint(item.value.count))
            out.append(item.value)
        }
        return out
    }

    // MARK: parsing

    static func parse(_ data: Data) throws -> HuaweiTLV {
        let buf = [UInt8](data)
        var items: [Item] = []
        var i = 0
        while i < buf.count {
            let tag = buf[i]
            i += 1
            // Encrypted payloads can end with one stray zero byte; ignore it.
            if i == buf.count && tag == 0 { break }
            let (size, used) = try huaweiDecodeVarint(buf, at: i)
            i += used
            guard size <= buf.count - i else {
                throw HuaweiTLVError.truncated(tag: tag, claimed: size, left: buf.count - i)
            }
            items.append(Item(tag: tag, value: Data(buf[i ..< i + size])))
            i += size
        }
        return HuaweiTLV(items: items)
    }

    // MARK: reading

    func contains(_ tag: UInt8) -> Bool { items.contains { $0.tag == tag } }

    func get(_ tag: UInt8) throws -> Data {
        guard let item = items.first(where: { $0.tag == tag }) else { throw HuaweiTLVError.missingTag(tag) }
        return item.value
    }

    func get(_ tag: UInt8, default fallback: Data) -> Data {
        items.first(where: { $0.tag == tag })?.value ?? fallback
    }

    func getAll(_ tag: UInt8) -> [Data] { items.filter { $0.tag == tag }.map(\.value) }

    /// Big-endian unsigned int of whatever width the band sent.
    func uint(_ tag: UInt8) throws -> Int { huaweiBigEndian(try get(tag)) }

    func uint(_ tag: UInt8, default fallback: Int) -> Int {
        contains(tag) ? huaweiBigEndian(get(tag, default: Data())) : fallback
    }

    func byte(_ tag: UInt8) throws -> Int {
        let v = try get(tag)
        guard let first = v.first else { throw HuaweiTLVError.emptyValue(tag) }
        return Int(first)
    }

    func byte(_ tag: UInt8, default fallback: Int) -> Int {
        guard contains(tag), let first = get(tag, default: Data()).first else { return fallback }
        return Int(first)
    }

    func string(_ tag: UInt8) throws -> String { String(decoding: try get(tag), as: UTF8.self) }

    func string(_ tag: UInt8, default fallback: String) -> String {
        contains(tag) ? String(decoding: get(tag, default: Data()), as: UTF8.self) : fallback
    }

    func child(_ tag: UInt8) throws -> HuaweiTLV { try HuaweiTLV.parse(try get(tag)) }

    func children(_ tag: UInt8) throws -> [HuaweiTLV] { try getAll(tag).map { try HuaweiTLV.parse($0) } }

    var description: String {
        let inner = items.map { item in
            String(format: "%02x=", item.tag) + (item.value.isEmpty ? "-" : huaweiHex(item.value))
        }
        return "TLV(" + inner.joined(separator: " ") + ")"
    }
}

/// Lowercase hex.
func huaweiHex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

/// Bytes from a hex string (spaces allowed); nil when malformed.
func huaweiData(hex: String) -> Data? {
    let chars = Array(hex.filter { !$0.isWhitespace })
    guard chars.count % 2 == 0 else { return nil }
    var out = Data(capacity: chars.count / 2)
    var i = 0
    while i < chars.count {
        guard let b = UInt8(String(chars[i ... i + 1]), radix: 16) else { return nil }
        out.append(b)
        i += 2
    }
    return out
}
