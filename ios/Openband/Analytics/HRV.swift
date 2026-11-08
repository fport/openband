import Foundation

/// Nightly HRV from the sleep file's RR intervals (plan section 5, "HRV"):
/// - only when RR exists;
/// - RR kept in 300-2000 ms, a beat jumping more than 20% from the one before is rejected;
/// - RMSSD per 5-minute window; the night's value is the median of the windows in the second
///   half of the night, with at least 3 such windows;
/// - always labelled approximate: the band sends RR in 10 ms steps.
struct HRVWindow: Codable, Equatable, Sendable {
    var start: Date
    var seconds: Double
    var beats: Int
    var validDifferences: Int
    var rmssd: Double?
    var secondHalf: Bool
    /// Long enough and clean enough to count.
    var usable: Bool
}

struct HRVResult: Codable, Equatable, Sendable {
    /// Milliseconds.
    var rmssd: Double
    var secondHalfWindows: Int
    var totalBeats: Int
    var approximate: Bool
}

enum HRV {
    static let rrRange = 300 ... 2000
    static let maxJump = 0.20
    static let windowSeconds = 300.0
    /// A trailing window shorter than this (80% of 5 min) is dropped.
    static let minWindowSeconds = 240.0
    /// A window counts when at least half of its successive differences survive and there are
    /// at least 20 of them (choice, algorithm v1).
    static let minValidFraction = 0.5
    static let minDifferences = 20
    static let minSecondHalfWindows = 3

    /// Successive differences that survive artifact rejection. A difference is kept when both
    /// beats are within 300-2000 ms and the second differs from the first by at most 20% of the
    /// first; so an out-of-range or jumping beat takes both differences it is part of with it.
    static func validDifferences(_ rr: [Int]) -> [Int] {
        guard rr.count >= 2 else { return [] }
        var out: [Int] = []
        for i in 1 ..< rr.count {
            let a = rr[i - 1], b = rr[i]
            guard rrRange.contains(a), rrRange.contains(b) else { continue }
            let d = b - a
            guard Double(abs(d)) <= maxJump * Double(a) else { continue }
            out.append(d)
        }
        return out
    }

    /// RMSSD over the valid differences; nil when there is none.
    static func rmssd(_ rr: [Int]) -> Double? {
        rmssd(differences: validDifferences(rr))
    }

    static func rmssd(differences d: [Int]) -> Double? {
        guard !d.isEmpty else { return nil }
        let sum = d.reduce(0.0) { $0 + Double($1 * $1) }
        return (sum / Double(d.count)).squareRoot()
    }

    /// The packet time stamp's unit is not settled (seconds for types 16/17, milliseconds by
    /// Gadgetbridge's reading of type 1). Take the first reading that lands within an hour of
    /// the night: seconds, then milliseconds, then nanoseconds. Nil when none fits.
    static func resolveStart(tsRaw: Int64, bedTime: Date, wakeTime: Date) -> Date? {
        let lo = bedTime.timeIntervalSince1970 - 3600
        let hi = wakeTime.timeIntervalSince1970 + 3600
        for divisor in [1.0, 1000.0, 1_000_000_000.0] {
            let t = Double(tsRaw) / divisor
            if t >= lo, t <= hi { return Date(timeIntervalSince1970: t) }
        }
        return nil
    }

    /// Splits every packet into 5-minute windows by the beats' own running time. A packet whose
    /// time stamp cannot be placed starts where the previous packet ended (bed time for the first).
    static func windows(_ segments: [RRSegment], bedTime: Date, wakeTime: Date) -> [HRVWindow] {
        let middle = bedTime.addingTimeInterval(wakeTime.timeIntervalSince(bedTime) / 2)
        var out: [HRVWindow] = []
        var cursor = bedTime
        for segment in segments {
            let start = resolveStart(tsRaw: segment.tsRaw, bedTime: bedTime, wakeTime: wakeTime) ?? cursor
            var windowStart = 0.0
            var elapsed = 0.0
            var beats: [Int] = []
            func close(final: Bool) {
                let seconds = elapsed - windowStart
                defer {
                    windowStart = elapsed
                    beats = []
                }
                guard !beats.isEmpty, !final || seconds >= minWindowSeconds else { return }
                let diffs = validDifferences(beats)
                let possible = max(beats.count - 1, 1)
                let usable = seconds >= minWindowSeconds && diffs.count >= minDifferences
                    && Double(diffs.count) >= minValidFraction * Double(possible)
                let begin = start.addingTimeInterval(windowStart)
                out.append(HRVWindow(start: begin, seconds: seconds, beats: beats.count, validDifferences: diffs.count,
                                     rmssd: rmssd(differences: diffs),
                                     secondHalf: begin.addingTimeInterval(seconds / 2) >= middle, usable: usable))
            }
            for rr in segment.intervalsMs {
                beats.append(rr)
                elapsed += Double(min(max(rr, 0), rrRange.upperBound)) / 1000
                if elapsed - windowStart >= windowSeconds { close(final: false) }
            }
            close(final: true)
            cursor = start.addingTimeInterval(elapsed)
        }
        return out
    }

    /// The night's HRV, or nil with the number of usable second-half windows found.
    static func nightly(_ segments: [RRSegment], bedTime: Date, wakeTime: Date) -> (result: HRVResult?, windows: Int) {
        let all = windows(segments, bedTime: bedTime, wakeTime: wakeTime)
        let late = all.filter { $0.usable && $0.secondHalf }.compactMap(\.rmssd)
        guard late.count >= minSecondHalfWindows, let median = Stats.median(late) else { return (nil, late.count) }
        let beats = segments.reduce(0) { $0 + $1.intervalsMs.count }
        return (HRVResult(rmssd: median, secondHalfWindows: late.count, totalBeats: beats, approximate: true), late.count)
    }
}
