import Foundation

/// Steps per hour of one day for the UI (bug fix 2: steps between two syncs used to pile up in
/// the hour of the later sync).
///
/// The minute file wins wherever it has records. After its last record (or for a day without
/// one) the cumulative live readings fill in: the rise between two readings is spread evenly
/// over the time between them.
enum HourlySteps {
    /// Before the first live reading of a day there is no lower anchor (the band counts from
    /// midnight, but the night is mostly asleep); its count is spread over at most this long.
    static let firstReadingSpread: TimeInterval = 2 * 3600

    /// - minuteSteps: the day's 1440 minute slots (nil = no record), or nil without a minute file.
    /// - dayStart: local midnight of the day; hour h is [dayStart + h h, dayStart + (h+1) h).
    /// - readings: cumulative step counts of that day (live samples), any order.
    static func compute(minuteSteps: [Int?]?, dayStart: Date, readings: [(ts: Date, steps: Int)]) -> [Int] {
        var hours = [Double](repeating: 0, count: 24)
        var anchor: (ts: Date, steps: Int)?

        if let minuteSteps {
            var total = 0
            var last: Int?
            for (i, v) in minuteSteps.prefix(1440).enumerated() {
                guard let v else { continue }
                hours[min(i / 60, 23)] += Double(v)
                total += v
                last = i
            }
            if let last { anchor = (dayStart.addingTimeInterval(TimeInterval((last + 1) * 60)), total) }
        }

        let dayEnd = dayStart.addingTimeInterval(86_400)
        let sorted = readings.filter { $0.ts >= dayStart && $0.ts < dayEnd }.sorted { $0.ts < $1.ts }
        var previous = anchor
        for reading in sorted {
            if let a = anchor, reading.ts <= a.ts { continue }  // the minute file already covers it
            if let p = previous {
                if reading.steps >= p.steps {
                    spread(Double(reading.steps - p.steps), from: p.ts, to: reading.ts, dayStart: dayStart, into: &hours)
                    previous = reading
                } else if anchor == nil || p.ts != anchor?.ts {
                    // The count went down (band reset): start again from this reading.
                    previous = reading
                }
            } else {
                let from = max(dayStart, reading.ts.addingTimeInterval(-firstReadingSpread))
                spread(Double(reading.steps), from: from, to: reading.ts, dayStart: dayStart, into: &hours)
                previous = reading
            }
        }
        return roundPreservingTotal(hours)
    }

    /// Adds `amount` to the hours overlapping [from, to] in proportion to the overlap.
    static func spread(_ amount: Double, from: Date, to: Date, dayStart: Date, into hours: inout [Double]) {
        guard amount > 0 else { return }
        let a = from.timeIntervalSince(dayStart), b = to.timeIntervalSince(dayStart)
        guard b > a else {
            hours[min(max(Int(b / 3600), 0), 23)] += amount
            return
        }
        for h in 0 ..< 24 {
            let lo = max(a, Double(h) * 3600), hi = min(b, Double(h + 1) * 3600)
            if hi > lo { hours[h] += amount * (hi - lo) / (b - a) }
        }
    }

    /// Integers whose sum equals the rounded total (largest remainder).
    static func roundPreservingTotal(_ values: [Double]) -> [Int] {
        let total = Int(values.reduce(0, +).rounded())
        var out = values.map { Int($0.rounded(.down)) }
        var missing = total - out.reduce(0, +)
        let order = values.indices.sorted { (values[$0] - values[$0].rounded(.down)) > (values[$1] - values[$1].rounded(.down)) }
        var i = 0
        while missing > 0, !order.isEmpty {
            out[order[i % order.count]] += 1
            missing -= 1
            i += 1
        }
        return out
    }
}
