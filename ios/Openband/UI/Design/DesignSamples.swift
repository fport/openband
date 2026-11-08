import Foundation

/// Deterministic sample data for component previews and the design gallery. Nothing here
/// touches the band, SwiftData or analytics.
enum DesignSamples {
    /// Tuesday 14 October 2026, 10:42 local time.
    static let now: Date = {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 10, 14, 10, 42)
        return Calendar.current.date(from: c) ?? .now
    }()

    /// Daily points ending today, oldest first.
    static func days(_ values: [Double?], ending end: Date = now) -> [TrendPoint] {
        let calendar = Calendar.current
        let last = calendar.startOfDay(for: end)
        return values.enumerated().compactMap { index, value in
            calendar.date(byAdding: .day, value: index - (values.count - 1), to: last).map { TrendPoint(date: $0, value: value) }
        }
    }

    /// A smooth wobble plus a deterministic jitter, so series look measured, not generated.
    private static func series(_ count: Int, base: Double, swing: Double, jitter: Double, seed: UInt64,
                               gaps: Set<Int> = [], round step: Double = 1) -> [Double?] {
        var state = seed
        return (0..<count).map { i in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(state >> 33) / Double(1 << 31) - 0.5
            let value = base + swing * sin(Double(i) / 4.3) + jitter * noise
            return gaps.contains(i) ? nil : (value / step).rounded() * step
        }
    }

    static let recovery = series(90, base: 61, swing: 12, jitter: 22, seed: 7, gaps: [40, 41]).map { $0.map { min(99, max(8, $0)) } }
    static let sleepScore = series(90, base: 78, swing: 8, jitter: 16, seed: 11).map { $0.map { min(98, max(30, $0)) } }
    static let sleepHours = series(90, base: 7.1, swing: 0.5, jitter: 1.4, seed: 3, gaps: [12], round: 0.1)
    static let strain = series(90, base: 10.8, swing: 2.5, jitter: 5, seed: 5, round: 0.1).map { $0.map { min(20.5, max(2, $0)) } }
    static let restingHR = series(90, base: 56, swing: 2, jitter: 3, seed: 13, gaps: [60, 61, 62])
    static let steps = series(90, base: 7_900, swing: 1_800, jitter: 4_200, seed: 17, gaps: [85], round: 1).map { $0.map { max(800, $0) } }
    static let bloodOxygen = series(90, base: 96, swing: 0.6, jitter: 2, seed: 19).map { $0.map { min(99, $0) } }

    /// Last seven values of a series, for sparklines.
    static func week(_ values: [Double?]) -> [Double?] { Array(values.suffix(7)) }

    /// Monday night, 13 October: in bed 23:52, up 07:04; 7h 12m with 24m awake.
    static let night: [HypnogramSegment] = {
        let plan: [(HypnogramStage, Double)] = [
            (.light, 26), (.deep, 42), (.light, 24), (.rem, 14), (.awake, 4),
            (.light, 36), (.deep, 28), (.light, 26), (.rem, 22), (.awake, 6),
            (.light, 44), (.deep, 16), (.light, 34), (.rem, 26), (.awake, 5),
            (.light, 40), (.rem, 30), (.awake, 9),
        ]
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 10, 13, 23, 52)
        var cursor = Calendar.current.date(from: c) ?? .now
        return plan.map { stage, minutes in
            let end = cursor.addingTimeInterval(minutes * 60)
            defer { cursor = end }
            return HypnogramSegment(stage: stage, start: cursor, end: end)
        }
    }()

    /// Yesterday's strain: 11.2, Moderate.
    static let zones: [HRZone] = [
        HRZone(index: 1, lowerBPM: 98, upperBPM: 115, minutes: 64),
        HRZone(index: 2, lowerBPM: 115, upperBPM: 128, minutes: 38),
        HRZone(index: 3, lowerBPM: 128, upperBPM: 145, minutes: 24),
        HRZone(index: 4, lowerBPM: 145, upperBPM: 162, minutes: 9),
        HRZone(index: 5, lowerBPM: 162, upperBPM: nil, minutes: 2),
    ]

    static let emptyZones: [HRZone] = zones.map { HRZone(index: $0.index, lowerBPM: $0.lowerBPM, upperBPM: $0.upperBPM, minutes: 0) }
}
