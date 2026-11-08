import Foundation

// MARK: - Resting heart rate

/// Resting HR (plan section 5): the first that exists of
/// 1. the lowest 5-minute average during sleep (high confidence),
/// 2. the band's own `hrResting` from the daily summary (medium),
/// 3. the 10th percentile of daytime minutes without steps (low).
struct RestingHR: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case sleep, band, daytime
    }

    var value: Double
    var source: Source

    var confidence: ConfidenceLevel {
        switch source {
        case .sleep: return .high
        case .band: return .medium
        case .daytime: return .low
        }
    }

    /// Daytime fallback needs this many still minutes with a heart rate.
    static let minDaytimeMinutes = 30
    static let daytimePercentile = 0.10

    static func compute(sleepLowest5Min: Double?, bandValue: Int?, minutes: MinuteSeries?, sleeps: [SleepInput]) -> RestingHR? {
        if let v = sleepLowest5Min, ValidRange.heartRate.contains(Int(v.rounded())) { return RestingHR(value: v, source: .sleep) }
        if let b = ValidRange.hr(bandValue) { return RestingHR(value: Double(b), source: .band) }
        guard let minutes else { return nil }
        var still: [Double] = []
        for i in 0 ..< MinuteSeries.slots {
            guard minutes.steps[i] == 0, let hr = ValidRange.hr(minutes.heartRate[i]) else { continue }
            let t = minutes.time(ofMinute: i)
            guard !sleeps.contains(where: { $0.contains(t) }) else { continue }
            still.append(Double(hr))
        }
        guard still.count >= minDaytimeMinutes, let p = Stats.percentile(still, daytimePercentile) else { return nil }
        return RestingHR(value: p, source: .daytime)
    }
}

// MARK: - Recovery

struct RecoveryContributor: Codable, Equatable, Sendable {
    enum Name: String, Codable, Sendable, CaseIterable {
        case hrv
        case restingHR = "resting_hr"
        case sleep
        /// The previous day's strain.
        case strain
    }

    var name: Name
    /// Weight in the set that was used (0 when this contributor is not part of it).
    var weight: Double
    var today: Double?
    var baseline: Baseline?
    /// Signed so that positive is good for recovery.
    var z: Double?
    var subscore: Double?
}

struct RecoveryResult: Codable, Equatable, Sendable {
    var score: Int?
    var usesHRV: Bool
    var contributors: [RecoveryContributor]
    var confidence: Confidence
}

/// Recovery 0-100 (plan section 5): each contributor is f(z) = 60 + 20 z clamped to 0-100, so
/// "your normal" scores 60, and the score is their weighted mean.
/// With HRV: HRV 40, resting HR 25, sleep 25, previous day's strain 10.
/// Without (no RR, or no usable HRV baseline yet): resting HR 45, sleep 40, strain 15, and the
/// confidence is at most medium.
///
/// Choices (algorithm v1):
/// - z is taken against each metric's own 14-day baseline; a contributor whose baseline is still
///   calibrating (< 3 days) is left out;
/// - f is applied per contributor and then averaged (the same as f of the mean z unless a
///   contributor hits 0 or 100), so the rows on screen add up to the score;
/// - no score without at least one of HRV and resting HR.
enum Recovery {
    static let withHRV: [RecoveryContributor.Name: Double] = [.hrv: 40, .restingHR: 25, .sleep: 25, .strain: 10]
    static let withoutHRV: [RecoveryContributor.Name: Double] = [.restingHR: 45, .sleep: 40, .strain: 15]

    static func f(_ z: Double) -> Double { Stats.clamp(60 + 20 * z, 0, 100) }

    struct Inputs: Equatable, Sendable {
        var hrv: Double?
        /// Previous valid nights, most recent first.
        var hrvHistory: [Double] = []
        /// The night had RR intervals at all.
        var hasRR = false
        /// Usable second-half windows found (for the reason when HRV is nil despite RR).
        var hrvWindows = 0
        var restingHR: RestingHR?
        var restingHRHistory: [Double] = []
        var sleepScore: Double?
        var sleepHistory: [Double] = []
        /// Strain of the day before.
        var strainYesterday: Double?
        /// Strains of the days before that one, most recent first.
        var strainHistory: [Double] = []
    }

    static func score(_ input: Inputs) -> RecoveryResult {
        struct Part {
            var name: RecoveryContributor.Name
            var today: Double?
            var baseline: Baseline?
            /// +1: higher is better (HRV, sleep); -1: lower is better (resting HR, strain).
            var sign: Double

            var usable: Bool { today != nil && baseline != nil && baseline?.status != .calibrating }
            var z: Double? {
                guard usable, let today, let baseline else { return nil }
                return sign * baseline.z(today)
            }
        }

        let parts = [
            Part(name: .hrv, today: input.hrv, baseline: Baseline.compute(input.hrvHistory, floor: .hrv), sign: 1),
            Part(name: .restingHR, today: input.restingHR?.value,
                 baseline: Baseline.compute(input.restingHRHistory, floor: .restingHR), sign: -1),
            Part(name: .sleep, today: input.sleepScore, baseline: Baseline.compute(input.sleepHistory, floor: .sleepScore), sign: 1),
            Part(name: .strain, today: input.strainYesterday,
                 baseline: Baseline.compute(input.strainHistory, floor: .strain), sign: -1),
        ]
        let usesHRV = parts[0].usable
        let weights = usesHRV ? withHRV : withoutHRV

        let rows = parts.map { p -> RecoveryContributor in
            let w = weights[p.name] ?? 0
            return RecoveryContributor(name: p.name, weight: w, today: p.today, baseline: p.baseline, z: p.z,
                                       subscore: w > 0 ? p.z.map(f) : nil)
        }

        var confidence = Confidence(.high)
        func label(_ name: RecoveryContributor.Name) -> String { name.rawValue }

        if !usesHRV {
            if !input.hasRR {
                confidence.cap(.medium, ConfidenceReason(.noRR))
            } else if input.hrv == nil {
                confidence.cap(.medium, ConfidenceReason(.hrvTooFewWindows, Double(input.hrvWindows), Double(HRV.minSecondHalfWindows)))
            } else {
                confidence.cap(.medium, ConfidenceReason(.baselineCalibrating, Double(parts[0].baseline?.count ?? 0),
                                                         Double(Baseline.window), detail: label(.hrv)))
            }
        } else {
            confidence.note(ConfidenceReason(.hrvApproximate))
        }

        guard parts[0].usable || parts[1].usable else {
            var none = Confidence(.none, reasons: confidence.reasons)
            for p in parts[0 ... 1] where p.today != nil && !p.usable {
                none.note(ConfidenceReason(.baselineCalibrating, Double(p.baseline?.count ?? 0), Double(Baseline.window),
                                           detail: label(p.name)))
            }
            if input.restingHR == nil, input.hrv == nil { none.note(ConfidenceReason(.noHeartRate)) }
            return RecoveryResult(score: nil, usesHRV: false, contributors: rows, confidence: none)
        }

        for (p, row) in zip(parts, rows) where row.weight > 0 {
            if p.usable, let b = p.baseline, b.status == .low {
                confidence.cap(.low, ConfidenceReason(.baselineShort, Double(b.count), Double(Baseline.window), detail: label(p.name)))
            } else if !p.usable {
                if p.today != nil {
                    confidence.cap(.medium, ConfidenceReason(.baselineCalibrating, Double(p.baseline?.count ?? 0),
                                                             Double(Baseline.window), detail: label(p.name)))
                } else {
                    confidence.cap(.medium, ConfidenceReason(.missingContributor, detail: label(p.name)))
                }
            }
        }
        if parts[1].usable, let rhr = input.restingHR {
            switch rhr.source {
            case .sleep: break
            case .band: confidence.cap(.medium, ConfidenceReason(.restingHRFromBand))
            case .daytime: confidence.cap(.low, ConfidenceReason(.restingHRFromDaytime))
            }
        }

        let used = rows.filter { $0.weight > 0 && $0.subscore != nil }
        let weight = used.reduce(0) { $0 + $1.weight }
        let score = used.reduce(0) { $0 + $1.weight * ($1.subscore ?? 0) } / weight
        return RecoveryResult(score: Int(score.rounded()), usesHRV: usesHRV, contributors: rows, confidence: confidence)
    }
}
