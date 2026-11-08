import Foundation

/// What the user told us about themselves. Everything is optional ("unknown" by default); the
/// formulas fall back to population defaults and say so in their confidence reasons.
struct Profile: Equatable, Codable, Sendable {
    enum Sex: String, Codable, Sendable, CaseIterable {
        case male, female, unknown
    }

    var age: Int?
    var sex: Sex
    var heightCm: Double?
    var weightKg: Double?
    var maxHROverride: Int?
    var sleepNeedMinutes: Int?

    init(age: Int? = nil, sex: Sex = .unknown, heightCm: Double? = nil, weightKg: Double? = nil,
         maxHROverride: Int? = nil, sleepNeedMinutes: Int? = nil) {
        self.age = age
        self.sex = sex
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.maxHROverride = maxHROverride
        self.sleepNeedMinutes = sleepNeedMinutes
    }

    static let unknown = Profile()

    // MARK: derived values used by the formulas

    /// Age assumed when unknown, for max HR only (plan: Tanaka 208 - 0.7 x age).
    static let assumedAge = 35
    /// Sleep need when not set: 8 h (7-9 h is the usual adult recommendation).
    static let defaultSleepNeedMinutes = 480

    /// Override, else 208 - 0.7 x age, else the same with the assumed age.
    var maxHR: Double {
        if let maxHROverride, maxHROverride > 100 { return Double(maxHROverride) }
        return 208 - 0.7 * Double(age ?? Self.assumedAge)
    }

    var maxHRIsKnown: Bool { (maxHROverride ?? 0) > 100 || age != nil }

    /// Banister TRIMP weighting factor: 1.92 men, 1.67 women, 1.80 unknown (plan section 5).
    var trimpK: Double {
        switch sex {
        case .male: return 1.92
        case .female: return 1.67
        case .unknown: return 1.80
        }
    }

    var sleepNeed: Int { sleepNeedMinutes.flatMap { $0 >= 240 ? $0 : nil } ?? Self.defaultSleepNeedMinutes }

    // MARK: storage

    static let defaultsKey = "freeband.profile.v1"

    static func load(from defaults: UserDefaults = .standard) -> Profile {
        guard let data = defaults.data(forKey: defaultsKey),
              let profile = try? JSONDecoder().decode(Profile.self, from: data) else { return .unknown }
        return profile
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
