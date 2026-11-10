import Foundation
import SwiftData

/// A meal the user photographed and an AI estimated. Estimates, never measurements: the screens
/// say so and every number stays editable.
@Model
final class MealEntry {
    @Attribute(.unique) var id: UUID
    var eatenAt: Date
    var title: String
    var kcal: Int
    var proteinGrams: Double
    var carbGrams: Double
    var fatGrams: Double
    /// 0–1, how sure the model said it was.
    var confidence: Double
    /// What the model listed, one item per line, as "name · portion · kcal".
    var items: String
    @Attribute(.externalStorage) var photo: Data?
    /// "openai" or "anthropic", plus the model, for the record.
    var provider: String
    var createdAt: Date

    init(eatenAt: Date = Date(), title: String = "", provider: String = "") {
        id = UUID()
        self.eatenAt = eatenAt
        self.title = title
        kcal = 0
        proteinGrams = 0
        carbGrams = 0
        fatGrams = 0
        confidence = 0
        items = ""
        self.provider = provider
        createdAt = Date()
    }

    var day: DayKey { DayKey(date: eatenAt, offsetMinutes: TimeZone.current.secondsFromGMT(for: eatenAt) / 60) }
}

/// A body check-in: the photos stay on the phone, the written assessment is what comes back.
@Model
final class BodyScan {
    @Attribute(.unique) var id: UUID
    var takenAt: Date
    var weightKg: Double
    var heightCm: Double
    var age: Int
    /// "male", "female" or "" when not said.
    var sex: String
    /// `CoachGoal.rawValue`.
    var goal: String
    /// `ActivityLevel.rawValue`.
    var activity: String
    /// Estimated body-fat percentage, with the range the model gave.
    var bodyFatLow: Double
    var bodyFatHigh: Double
    /// The assessment, as Markdown.
    var summary: String
    /// The plan, as Markdown.
    var plan: String
    var provider: String
    @Attribute(.externalStorage) var frontPhoto: Data?
    @Attribute(.externalStorage) var sidePhoto: Data?
    @Attribute(.externalStorage) var backPhoto: Data?

    init(takenAt: Date = Date()) {
        id = UUID()
        self.takenAt = takenAt
        weightKg = 0
        heightCm = 0
        age = 0
        sex = ""
        goal = CoachGoal.lose.rawValue
        activity = ActivityLevel.moderate.rawValue
        bodyFatLow = 0
        bodyFatHigh = 0
        summary = ""
        plan = ""
        provider = ""
    }

    var bodyFatText: String? {
        guard bodyFatLow > 0, bodyFatHigh > 0 else { return nil }
        return bodyFatLow == bodyFatHigh ? "\(Int(bodyFatLow))%" : "\(Int(bodyFatLow))–\(Int(bodyFatHigh))%"
    }
}

enum CoachGoal: String, CaseIterable, Identifiable, Sendable {
    case lose, maintain, gain

    var id: String { rawValue }

    var name: String {
        switch self {
        case .lose: String(localized: "Lose weight", comment: "Coach goal")
        case .maintain: String(localized: "Maintain", comment: "Coach goal")
        case .gain: String(localized: "Build muscle", comment: "Coach goal")
        }
    }
}

enum ActivityLevel: String, CaseIterable, Identifiable, Sendable {
    case sedentary, light, moderate, active, veryActive

    var id: String { rawValue }

    var name: String {
        switch self {
        case .sedentary: String(localized: "Sedentary", comment: "Activity level")
        case .light: String(localized: "Light", comment: "Activity level")
        case .moderate: String(localized: "Moderate", comment: "Activity level")
        case .active: String(localized: "Active", comment: "Activity level")
        case .veryActive: String(localized: "Very active", comment: "Activity level")
        }
    }

    /// The usual Harris–Benedict multipliers, for the maintenance estimate.
    var multiplier: Double {
        switch self {
        case .sedentary: 1.2
        case .light: 1.375
        case .moderate: 1.55
        case .active: 1.725
        case .veryActive: 1.9
        }
    }
}
