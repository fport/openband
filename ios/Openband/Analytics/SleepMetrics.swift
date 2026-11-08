import Foundation

/// What one sleep session measured, before any scoring.
struct SleepMetrics: Codable, Equatable, Sendable {
    var bedTime: Date
    var wakeTime: Date
    var inBedMinutes: Double
    var totalSleepMinutes: Double
    /// False when the band did not stage the night (no deep/REM split).
    var stagesAvailable: Bool
    var efficiency: Double?
    var deepMinutes: Double?
    var lightMinutes: Double?
    var remMinutes: Double?
    var awakeMinutes: Double?
    var deepFraction: Double?
    var remFraction: Double?
    var wakeCount: Int?
    /// Wake after sleep onset, minutes.
    var wasoMinutes: Double?
    var midSleep: Date
    /// Mid-sleep as minute of the local day (0..<1440), for the regularity contributor.
    var midSleepMinute: Double
    var hrAverage: Double?
    var hrMinimum: Double?
    /// Lowest 5-minute average during the sleep (the resting HR candidate).
    var hrLowest5Min: Double?
    /// Mean HR in the waking hours before bed, the reference for the HR dip.
    var awakeHRMean: Double?
    /// (awake mean - sleep mean) / awake mean.
    var hrDip: Double?
    var spo2Average: Double?
    var spo2Minimum: Double?
    var spo2Below90Minutes: Double?
}

enum SleepMetricsCalc {
    /// A sample of the sleep file's HR/SpO2 series covers at most this long.
    static let maxSampleSpanSeconds = 600
    /// Waking hours before bed whose HR mean is the dip reference (choice, algorithm v1).
    static let awakeWindowHours = 14.0
    static let minAwakeHRSamples = 20

    static func compute(_ s: SleepInput, minutes: [MinuteSeries], awakeHRMean: Double?) -> SleepMetrics {
        let inBed = s.inBedMinutes

        // Stage minutes: the band's own totals, else the segments.
        var deep = s.deepMinutes.map(Double.init)
        var light = s.lightMinutes.map(Double.init)
        var rem = s.remMinutes.map(Double.init)
        var awake = s.awakeMinutes.map(Double.init)
        if deep == nil, light == nil, rem == nil, s.segments.contains(where: { $0.stage.isSleep }) {
            func total(_ k: StageKind) -> Double { Double(s.segments.filter { $0.stage == k }.reduce(0) { $0 + $1.minutes }) }
            deep = total(.deep)
            light = total(.light)
            rem = total(.rem)
            awake = total(.awake)
        }
        let staged = deep != nil || light != nil || rem != nil
        let total = staged ? (deep ?? 0) + (light ?? 0) + (rem ?? 0) : max(inBed - (awake ?? 0), 0)
        // A night of only light sleep means the band did not stage it (no deep/REM split).
        let stagesAvailable = staged && deep != nil && rem != nil && total > 0 && ((deep ?? 0) + (rem ?? 0)) > 0

        // Wake after sleep onset and wake count from the timeline when there is one.
        var waso: Double?
        var wakeCount = s.wakeCount
        let sleepSegments = s.segments.filter { $0.stage.isSleep }
        if let first = sleepSegments.map(\.start).min(), let last = sleepSegments.map(\.end).max() {
            let inside = s.segments.filter { $0.stage == .awake && $0.start >= first && $0.end <= last }
            waso = Double(inside.reduce(0) { $0 + $1.minutes })
            if wakeCount == nil {
                // Each maximal run of awake segments between the first and last sleep is one waking.
                var runs = 0
                var inRun = false
                for seg in s.segments.sorted(by: { $0.start < $1.start }) where seg.start >= first && seg.end <= last {
                    if seg.stage == .awake {
                        if !inRun { runs += 1 }
                        inRun = true
                    } else if seg.stage.isSleep {
                        inRun = false
                    }
                }
                wakeCount = runs
            }
        } else if let awake {
            // No timeline: the band's awake minutes within the session stand in for WASO.
            waso = awake
        }

        let mid = s.bedTime.addingTimeInterval(s.wakeTime.timeIntervalSince(s.bedTime) / 2)
        let localSeconds = mid.timeIntervalSince1970 + Double(s.tzOffsetMinutes * 60)
        let midMinute = (localSeconds.truncatingRemainder(dividingBy: 86_400) + 86_400).truncatingRemainder(dividingBy: 86_400) / 60

        let hr = heartRatePerMinute(s, minutes: minutes)
        let hrValues = hr.compactMap { $0 }
        let hrAverage = Stats.mean(hrValues)
        var dip: Double?
        if let hrAverage, let awakeHRMean, awakeHRMean > 0 { dip = (awakeHRMean - hrAverage) / awakeHRMean }

        let spo2 = spo2Samples(s, minutes: minutes)
        let spo2Weight = spo2.reduce(0.0) { $0 + $1.minutes }
        let spo2Avg = spo2Weight > 0 ? spo2.reduce(0.0) { $0 + Double($1.value) * $1.minutes } / spo2Weight : nil

        return SleepMetrics(
            bedTime: s.bedTime, wakeTime: s.wakeTime, inBedMinutes: inBed, totalSleepMinutes: total,
            stagesAvailable: stagesAvailable,
            efficiency: inBed > 0 ? min(total / inBed, 1) : nil,
            deepMinutes: deep, lightMinutes: light, remMinutes: rem, awakeMinutes: awake,
            deepFraction: stagesAvailable ? (deep ?? 0) / total : nil,
            remFraction: stagesAvailable ? (rem ?? 0) / total : nil,
            wakeCount: wakeCount, wasoMinutes: waso, midSleep: mid, midSleepMinute: midMinute,
            hrAverage: hrAverage, hrMinimum: hrValues.min(), hrLowest5Min: lowestRollingAverage(hr),
            awakeHRMean: awakeHRMean, hrDip: dip,
            spo2Average: spo2Avg, spo2Minimum: spo2.map { Double($0.value) }.min(),
            spo2Below90Minutes: spo2.isEmpty ? nil : spo2.filter { $0.value < 90 }.reduce(0.0) { $0 + $1.minutes }
        )
    }

    /// Heart rate per minute of the session, [bedTime, wakeTime). The sleep file's own series wins;
    /// a sample covers its interval (capped at 10 min) and several samples in one minute are
    /// averaged. Without it, the minute file's HR in the session. Values outside 30-220 dropped.
    static func heartRatePerMinute(_ s: SleepInput, minutes: [MinuteSeries]) -> [Double?] {
        let count = Int(s.inBedMinutes.rounded(.up))
        guard count > 0 else { return [] }
        var sum = [Double](repeating: 0, count: count)
        var n = [Int](repeating: 0, count: count)
        let samples = s.heartRate.filter { ValidRange.heartRate.contains($0.value) }
        if !samples.isEmpty {
            let span = min(max(s.hrIntervalSeconds, 1), maxSampleSpanSeconds)
            for sample in samples {
                let first = Int((sample.ts.timeIntervalSince(s.bedTime) / 60).rounded(.down))
                let last = Int(((sample.ts.timeIntervalSince(s.bedTime) + Double(span) - 1) / 60).rounded(.down))
                guard last >= 0, first < count else { continue }
                for m in max(first, 0) ... min(last, count - 1) {
                    sum[m] += Double(sample.value)
                    n[m] += 1
                }
            }
        } else {
            for series in minutes {
                for i in 0 ..< MinuteSeries.slots {
                    guard let v = ValidRange.hr(series.heartRate[i]) else { continue }
                    let t = series.time(ofMinute: i)
                    guard s.contains(t) else { continue }
                    let m = Int(t.timeIntervalSince(s.bedTime) / 60)
                    guard m >= 0, m < count else { continue }
                    sum[m] += Double(v)
                    n[m] += 1
                }
            }
        }
        return (0 ..< count).map { n[$0] > 0 ? sum[$0] / Double(n[$0]) : nil }
    }

    /// Lowest mean over `window` consecutive minutes that hold at least `minValid` values.
    static func lowestRollingAverage(_ perMinute: [Double?], window: Int = 5, minValid: Int = 3) -> Double? {
        guard perMinute.count >= window else {
            let v = perMinute.compactMap { $0 }
            return v.count >= minValid ? Stats.mean(v) : nil
        }
        var best: Double?
        for start in 0 ... (perMinute.count - window) {
            let v = perMinute[start ..< start + window].compactMap { $0 }
            guard v.count >= minValid, let m = Stats.mean(v) else { continue }
            if best == nil || m < best! { best = m }
        }
        return best
    }

    /// SpO2 samples in the session with the minutes each stands for.
    static func spo2Samples(_ s: SleepInput, minutes: [MinuteSeries]) -> [(value: Int, minutes: Double)] {
        let own = s.spo2.filter { ValidRange.spo2.contains($0.value) && s.contains($0.ts) }
        if !own.isEmpty {
            let span = Double(min(max(s.spo2IntervalSeconds, 1), maxSampleSpanSeconds)) / 60
            return own.map { ($0.value, span) }
        }
        var out: [(value: Int, minutes: Double)] = []
        for series in minutes {
            for i in 0 ..< MinuteSeries.slots {
                guard let v = ValidRange.spo2(series.spo2[i]), s.contains(series.time(ofMinute: i)) else { continue }
                out.append((v, 1))
            }
        }
        return out
    }

    /// Mean of valid minute HR in the `awakeWindowHours` before bed, outside any sleep. Nil when
    /// fewer than 20 readings.
    static func awakeHRMean(before bedTime: Date, minutes: [MinuteSeries], sleeps: [SleepInput]) -> Double? {
        let from = bedTime.addingTimeInterval(-awakeWindowHours * 3600)
        var values: [Double] = []
        for series in minutes {
            for i in 0 ..< MinuteSeries.slots {
                guard let v = ValidRange.hr(series.heartRate[i]) else { continue }
                let t = series.time(ofMinute: i)
                guard t >= from, t < bedTime, !sleeps.contains(where: { $0.contains(t) }) else { continue }
                values.append(Double(v))
            }
        }
        return values.count >= minAwakeHRSamples ? Stats.mean(values) : nil
    }
}

// MARK: - Stress and SpO2 summaries (shown, not scored)

/// Time-weighted stress over the day and minutes per band (plan section 5: "Stres ve SpO2
/// skora girmez").
struct StressSummary: Codable, Equatable, Sendable {
    var average: Double
    var minutes: Double
    /// Xiaomi's bands: relaxed 1-39, mild 40-59, moderate 60-79, high 80-100.
    var bandMinutes: [Double]

    static let bandLowerBounds = [1, 40, 60, 80]
    /// A reading holds until the next one, at most 30 minutes (choice, algorithm v1).
    static let maxHoldMinutes = 30

    static func band(of value: Int) -> Int {
        bandLowerBounds.lastIndex { value >= $0 } ?? 0
    }

    static func compute(_ minutes: MinuteSeries) -> StressSummary? {
        let readings = (0 ..< MinuteSeries.slots).compactMap { i in ValidRange.stress(minutes.stress[i]).map { (i, $0) } }
        guard !readings.isEmpty else { return nil }
        var weighted = 0.0, total = 0.0
        var bands = [Double](repeating: 0, count: 4)
        for (n, reading) in readings.enumerated() {
            let next = n + 1 < readings.count ? readings[n + 1].0 : MinuteSeries.slots
            let hold = Double(min(next - reading.0, maxHoldMinutes))
            weighted += Double(reading.1) * hold
            total += hold
            bands[band(of: reading.1)] += hold
        }
        return StressSummary(average: weighted / total, minutes: total, bandMinutes: bands)
    }
}

/// Night SpO2: average, minimum, minutes below 90%.
struct SpO2Summary: Codable, Equatable, Sendable {
    var average: Double
    var minimum: Double
    var below90Minutes: Double
}
