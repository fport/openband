import Foundation

/// Things the app does with the band rather than read from it (port of src/openband/controls.py).
enum HuaweiControls {
    static let notifications: UInt8 = 0x02
    static let notificationSend: UInt8 = 0x01
    static let findPhone: UInt8 = 0x0B
    static let findPhoneEvent: UInt8 = 0x01
    static let findPhoneStop: UInt8 = 0x02

    static let typeGeneric = 0x7F
    static let textText = 0x01
    static let textSender = 0x02
    static let textTitle = 0x03
    /// Content format from the band's notification constraints; 2 is Gadgetbridge's default.
    static let encodingUTF8 = 0x02
    static let maxText = 300

    static func clip(_ text: String, limit: Int = maxText) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit - 1)) + "…"
    }

    /// A title, a sender and a text, shown and vibrated on the band.
    static func notification(id: Int, title: String, text: String, sender: String = "Openband") -> HuaweiRequest {
        var items = HuaweiTLV()
        for (kind, value) in [(textTitle, title), (textSender, sender), (textText, text)] {
            var element = HuaweiTLV().put(0x0E, byte: kind).put(0x0F, byte: encodingUTF8)
            if !value.isEmpty { element = element.put(0x10, string: clip(value)) }
            items = items.put(0x8D, tlv: element)
        }
        let tlv = HuaweiTLV()
            .put(0x01, u16: id & 0xFFFF)
            .put(0x02, byte: typeGeneric)
            .put(0x03, bool: true)
            .put(0x84, tlv: HuaweiTLV().put(0x8C, tlv: items))
            .put(0x11, string: "dev.openband")
        return HuaweiRequest(service: notifications, command: notificationSend, tlv: tlv)
    }

    /// "Find phone" was tapped on the band (tag 01 = 1) or stopped (0).
    static func findPhoneStarted(_ tlv: HuaweiTLV) -> Bool {
        guard let last = tlv.get(0x01, default: Data()).last else { return false }
        return last == 1
    }

    /// Ends the band's "finding" screen so the next tap counts again.
    static func stopFindPhone() -> HuaweiRequest {
        HuaweiRequest(service: findPhone, command: findPhoneStop, tlv: HuaweiTLV().put(0x01, byte: 2), expectsReply: false)
    }
}
