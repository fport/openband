import Foundation

struct StrainResult: Codable, Equatable, Sendable {
    /// 0-21.
    var strain: Double
    var trimp: Double
    /// Index 0: below Z1 (r 0.3-0.5, still counted), 1-5: Z1-Z5.
    var zoneMinutes: [Int]
    var zoneTrimp: [Double]
    /// TRIMP per local hour, 24 entries.
    var hourlyTrimp: [Double]
    var maxHR: Double
    var restingHR: Double
    var k: Double
    var awakeMinutes: Int
    /// Awake minutes with a measured heart rate.
    var heartRateMinutes: Int
    var coverage: Double
    /// Minutes whose HR was interpolated across a short gap (coverage below half only).
    var filledMinutes: Int
    /// Minutes counted as r = 0.4 for >= 100 steps without a measured HR (coverage below half only).
    var stepMinutes: Int
    var confidence: Confidence
}

/// Strain 0-21 (plan section 5):
///   max HR = 208 - 0.7 x age; r = (HR - resting) / (max - resting);
///   zones by r: Z1 0.5-0.6, Z2 0.6-0.7, Z3 0.7-0.8, Z4 0.8-0.9, Z5 >= 0.9;
///   TRIMP = sum over minutes of r x 0.64 x e^(k r), k 1.92 men / 1.67 women / 1.80 unknown;
///   strain = min(21, 21 x ln(1 + TRIMP/25) / ln 25), so TRIMP 100 -> 10.5 and 200 -> 14.3.
/// When HR covers less than half of the awake minutes: gaps of up to 10 minutes are filled
/// (linearly), minutes with >= 100 steps count as r = 0.4, and confidence is low.
///
/// Choices (algorithm v1):
/// - only awake minutes count (minutes with a record, outside every sleep session);
/// - r is clamped to 0...1 and minutes with r < 0.3 add nothing: the plan's sum over every awake
///   minute would give a sedentary day ~90 TRIMP (strain ~10) from sitting HR alone; 0.3 keeps
///   brisk walking (and the plan's r = 0.4 step fallback) and drops sitting;
/// - resting HR is the day's resting HR, else the baseline median, else 60 bpm (assumed).
enum Strain {
    static let activityFloor = 0.3
    static let zoneBounds = [0.5, 0.6, 0.7, 0.8, 0.9]
    static let stepFallbackSteps = 100
    static let stepFallbackR = 0.4
    static let maxFilledGap = 10
    static let lowCoverage = 0.5
    static let assumedRestingHR = 60.0

    static func strain(trimp: Double) -> Double {
        min(21, 21 * log(1 + max(trimp, 0) / 25) / log(25))
    }

    /// Heart-rate reserve fraction, clamped to 0...1.
    static func reserve(_ hr: Double, resting: Double, max maxHR: Double) -> Double {
        guard maxHR > resting else { return 0 }
        return Stats.clamp((hr - resting) / (maxHR - resting), 0, 1)
    }

    /// 0 below Z1, 1...5 for Z1...Z5.
    static func zone(_ r: Double) -> Int {
        zoneBounds.lastIndex { r >= $0 }.map { $0 + 1 } ?? 0
    }

    /// One minute's TRIMP; 0 below the activity floor.
    static func minuteTrimp(_ r: Double, k: Double) -> Double {
        r < activityFloor ? 0 : r * 0.64 * exp(k * r)
    }

    /// `now` cuts off minutes not yet lived (today); nil counts the whole day.
    static func compute(_ minutes: MinuteSeries, sleeps: [SleepInput], restingHR: Double?, profile: Profile,
                        now: Date? = nil) -> StrainResult? {
        let maxHR = profile.maxHR
        let rest = restingHR ?? assumedRestingHR
        let k = profile.trimpK

        var awake: [Int] = []
        for i in 0 ..< MinuteSeries.slots where minutes.hasRecord(i) {
            let t = minutes.time(ofMinute: i)
            if let now, t >= now { break }
            if sleeps.contains(where: { $0.contains(t) }) { continue }
            awake.append(i)
        }
        guard !awake.isEmpty else { return nil }

        let measured = awake.filter { ValidRange.hr(minutes.heartRate[$0]) != nil }
        let coverage = Double(measured.count) / Double(awake.count)
        var r = [Double?](repeating: nil, count: MinuteSeries.slots)
        for i in measured {
            r[i] = reserve(Double(minutes.heartRate[i] ?? 0), resting: rest, max: maxHR)
        }

        var filled = 0, stepped = 0
        if coverage < lowCoverage {
            // Short gaps: linear between the measured minutes on either side.
            for (a, b) in zip(measured, measured.dropFirst()) where b - a - 1 > 0 && b - a - 1 <= maxFilledGap {
                guard let ra = r[a], let rb = r[b] else { continue }
                for i in (a + 1) ..< b where r[i] == nil && minutes.hasRecord(i) {
                    let t = minutes.time(ofMinute: i)
                    guard !sleeps.contains(where: { $0.contains(t) }) else { continue }
                    r[i] = ra + (rb - ra) * Double(i - a) / Double(b - a)
                    filled += 1
                }
            }
            // Walking without a reading counts as light effort.
            for i in awake where ValidRange.hr(minutes.heartRate[i]) == nil && (minutes.steps[i] ?? 0) >= stepFallbackSteps {
                r[i] = max(r[i] ?? 0, stepFallbackR)
                stepped += 1
            }
        }

        var zoneMinutes = [Int](repeating: 0, count: 6)
        var zoneTrimp = [Double](repeating: 0, count: 6)
        var hourly = [Double](repeating: 0, count: 24)
        var trimp = 0.0
        for i in awake {
            guard let ri = r[i], ri >= activityFloor else { continue }
            let t = minuteTrimp(ri, k: k)
            let z = zone(ri)
            zoneMinutes[z] += 1
            zoneTrimp[z] += t
            hourly[i / 60] += t
            trimp += t
        }

        var confidence = Confidence(.high)
        if measured.isEmpty {
            confidence.cap(.low, ConfidenceReason(.noHeartRate))
        } else if coverage < lowCoverage {
            confidence.cap(.low, ConfidenceReason(.lowHeartRateCoverage, coverage))
            let gaps = zip(measured, measured.dropFirst()).map { Double($1 - $0) }
            if let gap = Stats.median(gaps) { confidence.note(ConfidenceReason(.sparseHeartRate, gap.rounded())) }
        }
        if !profile.maxHRIsKnown { confidence.cap(.medium, ConfidenceReason(.ageUnknown)) }
        if restingHR == nil { confidence.cap(.medium, ConfidenceReason(.restingHRAssumed)) }

        return StrainResult(strain: strain(trimp: trimp), trimp: trimp, zoneMinutes: zoneMinutes, zoneTrimp: zoneTrimp,
                            hourlyTrimp: hourly, maxHR: maxHR, restingHR: rest, k: k, awakeMinutes: awake.count,
                            heartRateMinutes: measured.count, coverage: coverage, filledMinutes: filled,
                            stepMinutes: stepped, confidence: confidence)
    }
}
