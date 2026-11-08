import Foundation

// Link framing: `5A | len(2) | slice | [flag] | service | command | body | crc16(2)`.
//
// `len` counts every byte from the slice byte up to (not including) the CRC. A message that does
// not fit in one slice is split; slice byte 1 opens it (and carries service and command), 2
// continues it and 3 closes it, each followed by a running flag byte. Slice byte 0 means
// unsliced. Port of openband/frame.py.

enum HuaweiFrameError: Error, Equatable, CustomStringConvertible {
    case sliceTooSmall(Int)
    case badMagic(String)
    case crcMismatch(computed: UInt16, stored: UInt16, frame: String)
    case tooShort(String)

    var description: String {
        switch self {
        case .sliceTooSmall(let size): return "slice size \(size) is too small"
        case .badMagic(let hex): return "bad magic: \(hex)"
        case let .crcMismatch(computed, stored, frame): return String(format: "crc mismatch %04x != %04x in ", computed, stored) + frame
        case .tooShort(let hex): return "message too short: \(hex)"
        }
    }
}

struct HuaweiMessage: Equatable {
    var service: UInt8
    var command: UInt8
    var body: Data
}

enum HuaweiFrame {
    static let magic: UInt8 = 0x5A
    static let defaultSliceSize = 0xF4

    /// CRC-16/CCITT (poly 0x1021, no reflection), init 0: CRC-16/XMODEM.
    static func crc16<Bytes: Sequence>(_ data: Bytes, crc initial: UInt16 = 0) -> UInt16 where Bytes.Element == UInt8 {
        var crc = initial
        for b in data {
            crc = (crc >> 8) | (crc << 8)
            crc ^= UInt16(b)
            crc ^= (crc & 0xFF) >> 4
            crc ^= crc << 12
            crc ^= (crc & 0xFF) << 5
        }
        return crc
    }

    private static func withCRC(_ head: [UInt8]) -> Data {
        let crc = crc16(head)
        return Data(head + [UInt8(crc >> 8), UInt8(crc & 0xFF)])
    }

    /// Frames one message; returns one or more packets to write in order.
    static func encode(service: UInt8, command: UInt8, body: Data, sliceSize: Int = defaultSliceSize) throws -> [Data] {
        let header = 5, footer = 2
        let maxBody = sliceSize - header - footer
        guard maxBody > 2 else { throw HuaweiFrameError.sliceTooSmall(sliceSize) }
        let b = [UInt8](body)
        let count = (b.count + 2 + maxBody - 1) / maxBody
        if count == 1 {
            let len = b.count + 3
            return [withCRC([magic, UInt8(len >> 8), UInt8(len & 0xFF), 0, service, command] + b)]
        }
        var packets: [Data] = []
        var pos = 0
        for i in 0 ..< count {
            let size = min(sliceSize, b.count - pos + header + footer)
            var content = size - header - footer
            let kind: UInt8 = i == count - 1 ? 3 : (i == 0 ? 1 : 2)
            let len = size - header
            var head: [UInt8] = [magic, UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF), kind, UInt8(i & 0xFF)]
            if i == 0 {
                head += [service, command]
                content -= 2
            }
            let end = min(pos + content, b.count)
            head += b[pos ..< end]
            pos = end
            packets.append(withCRC(head))
        }
        return packets
    }
}

/// Feed raw notification bytes; collect complete messages. Handles a frame split across
/// notifications, several frames in one notification, and sliced messages over several frames.
struct HuaweiReassembler {
    private var buffer: [UInt8] = []
    private var sliced: [UInt8] = []

    init() {}

    mutating func feed(_ data: Data) throws -> [HuaweiMessage] {
        buffer += data
        var out: [HuaweiMessage] = []
        while !buffer.isEmpty {
            guard buffer[0] == HuaweiFrame.magic else {
                let bad = huaweiHex(Data(buffer))
                buffer.removeAll()
                sliced.removeAll()
                throw HuaweiFrameError.badMagic(bad)
            }
            guard buffer.count >= 3 else { break }
            let length = Int(buffer[1]) << 8 | Int(buffer[2])
            let total = 3 + length + 2
            guard buffer.count >= total else { break }
            let frame = Array(buffer[0 ..< total])
            buffer.removeFirst(total)
            let stored = UInt16(frame[total - 2]) << 8 | UInt16(frame[total - 1])
            let computed = HuaweiFrame.crc16(frame[0 ..< total - 2])
            guard stored == computed else {
                sliced.removeAll()
                throw HuaweiFrameError.crcMismatch(computed: computed, stored: stored, frame: huaweiHex(Data(frame)))
            }
            guard frame.count >= 6 else { throw HuaweiFrameError.tooShort(huaweiHex(Data(frame))) }
            let kind = frame[3]
            var payload: [UInt8]
            if (1 ... 3).contains(kind) {
                let part = Array(frame[5 ..< total - 2])
                if kind == 1 { sliced = part } else { sliced += part }
                if kind != 3 { continue }
                payload = sliced
                sliced.removeAll()
            } else {
                payload = Array(frame[4 ..< total - 2])
            }
            guard payload.count >= 2 else { throw HuaweiFrameError.tooShort(huaweiHex(Data(payload))) }
            out.append(HuaweiMessage(service: payload[0], command: payload[1], body: Data(payload[2...])))
        }
        return out
    }
}
