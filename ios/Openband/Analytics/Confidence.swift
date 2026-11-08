import Foundation

/// How far a score can be trusted, always with the reasons (plan section 5: "Güven:
/// yüksek/orta/düşük/yok, her zaman gerekçe listesiyle").
enum ConfidenceLevel: String, Codable, Sendable, Comparable, CaseIterable {
    case none, low, medium, high

    private var rank: Int {
        switch self {
        case .none: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        }
    }

    static func < (a: ConfidenceLevel, b: ConfidenceLevel) -> Bool { a.rank < b.rank }
}

/// One reason, kept as a stable code plus arguments so the UI can localize it later; `text` is
/// the English (source language) rendering.
struct ConfidenceReason: Codable, Equatable, Sendable {
    enum Code: String, Codable, Sendable {
        /// a = valid days in the baseline, b = window (14).
        case baselineCalibrating = "baseline_calibrating"
        case baselineShort = "baseline_short"
        case noRR = "no_rr"
        /// a = windows found in the second half, b = needed.
        case hrvTooFewWindows = "hrv_too_few_windows"
        /// a = median minutes between heart-rate readings.
        case sparseHeartRate = "sparse_heart_rate"
        /// a = share of awake minutes with a heart rate (0...1).
        case lowHeartRateCoverage = "low_heart_rate_coverage"
        case restingHRFromBand = "resting_hr_from_band"
        case restingHRFromDaytime = "resting_hr_from_daytime"
        case restingHRAssumed = "resting_hr_assumed"
        case ageUnknown = "age_unknown"
        case noSleep = "no_sleep"
        case noStages = "no_stages"
        /// detail = contributor name.
        case missingContributor = "missing_contributor"
        /// a = available weight (out of 100).
        case estimated = "estimated"
        case noHeartRate = "no_heart_rate"
        case noData = "no_data"
        /// HRV comes from 10 ms RR resolution.
        case hrvApproximate = "hrv_approximate"
    }

    var code: Code
    var a: Double?
    var b: Double?
    var detail: String?

    init(_ code: Code, _ a: Double? = nil, _ b: Double? = nil, detail: String? = nil) {
        self.code = code
        self.a = a
        self.b = b
        self.detail = detail
    }

    private func n(_ v: Double?) -> String {
        guard let v else { return "?" }
        return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    var text: String {
        switch code {
        case .baselineCalibrating: return "\(detail.map { $0 + " " } ?? "")baseline calibrating (\(n(a))/3 days)"
        case .baselineShort: return "\(detail.map { $0 + " " } ?? "")baseline from \(n(a))/\(n(b)) days"
        case .noRR: return "no RR intervals"
        case .hrvTooFewWindows: return "HRV: \(n(a)) of \(n(b)) windows in the second half of the night"
        case .sparseHeartRate: return "heart rate every \(n(a)) min"
        case .lowHeartRateCoverage: return "heart rate covers \(Int(((a ?? 0) * 100).rounded()))% of awake minutes"
        case .restingHRFromBand: return "resting HR from the band's daily summary"
        case .restingHRFromDaytime: return "resting HR from daytime still minutes"
        case .restingHRAssumed: return "resting HR assumed"
        case .ageUnknown: return "age unknown, max HR assumed"
        case .noSleep: return "no sleep recorded"
        case .noStages: return "no sleep stages"
        case .missingContributor: return "missing: \(detail ?? "?")"
        case .estimated: return "estimate from \(n(a))/100 of the weights"
        case .noHeartRate: return "no heart rate"
        case .noData: return "no data"
        case .hrvApproximate: return "HRV approximate (10 ms resolution)"
        }
    }
}

struct Confidence: Codable, Equatable, Sendable {
    var level: ConfidenceLevel
    var reasons: [ConfidenceReason]

    init(_ level: ConfidenceLevel = .high, reasons: [ConfidenceReason] = []) {
        self.level = level
        self.reasons = reasons
    }

    static let none = Confidence(.none)

    /// Lowers the level to at most `level` and records why (the reason is kept even when the
    /// level was already lower, so the list stays complete).
    mutating func cap(_ level: ConfidenceLevel, _ reason: ConfidenceReason) {
        self.level = min(self.level, level)
        if !reasons.contains(reason) { reasons.append(reason) }
    }

    mutating func note(_ reason: ConfidenceReason) {
        if !reasons.contains(reason) { reasons.append(reason) }
    }
}
