import Foundation
import Security

/// What the screens show about a band, independent of the protocol that read it.
enum BandInfo {
    /// Today's totals. `heartRate` and `standingHours` stay 0 where the band does not report them.
    struct LiveStats: Equatable {
        let steps: UInt64
        let calories: UInt64
        let heartRate: UInt64
        let standingHours: UInt64
    }

    struct DeviceInfo: Equatable {
        let serial: String
        let firmware: String
        let model: String
    }

    struct DeviceState: Equatable {
        let charging: Bool
        let worn: Bool
        let asleep: Bool
    }
}

/// The keychain. Per band it keeps the Huawei pairing record: our own 16-byte key (created on this
/// phone, handed to the band when pairing), the identity we present, and the band's MAC.
enum Vault {
    private static let service = "dev.fport.openband"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func setData(_ value: Data, for account: String) {
        SecItemDelete(query(account) as CFDictionary)
        var item = query(account)
        item[kSecValueData as String] = value
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func data(_ account: String) -> Data? {
        var item = query(account)
        item[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func set(_ value: String, for account: String) { setData(Data(value.utf8), for: account) }
    static func get(_ account: String) -> String? { data(account).map { String(decoding: $0, as: UTF8.self) } }
    static func remove(_ account: String) { SecItemDelete(query(account) as CFDictionary) }

    private static func recordAccount(_ bandID: UUID) -> String { "band-record-\(bandID.uuidString)" }

    static func bandRecord(_ bandID: UUID) -> HuaweiBandRecord? {
        guard let raw = data(recordAccount(bandID)) else { return nil }
        return try? JSONDecoder().decode(HuaweiBandRecord.self, from: raw)
    }

    static func setBandRecord(_ record: HuaweiBandRecord, for bandID: UUID) {
        guard let raw = try? JSONEncoder().encode(record) else { return }
        setData(raw, for: recordAccount(bandID))
    }

    static func removeBandRecord(_ bandID: UUID) { remove(recordAccount(bandID)) }

    /// True once the band has accepted our key.
    static func isPaired(_ bandID: UUID) -> Bool { bandRecord(bandID)?.bonded == true }

    static var hubToken: String? {
        get { get("hub-token") }
        set { if let newValue { set(newValue, for: "hub-token") } else { remove("hub-token") } }
    }
}
