import Foundation

/// Personal normal for one metric (plan section 5, "Bazal"): the median of the previous 14 valid
/// days, sigma = 1.4826 x MAD with a floor. Fewer than 3 days is "calibrating", 3-6 days low
/// confidence, 7 or more normal.
struct Baseline: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        case calibrating, low, normal
    }

    /// The window: at most this many previous valid days.
    static let window = 14
    /// How far back to look for those 14 valid days (calendar days). The plan only says
    /// "previous 14 valid days"; 60 days keeps a long gap from reviving a stale normal.
    static let lookbackDays = 60

    /// Lower bound for sigma, so a very steady metric does not turn tiny changes into big z.
    struct Floor: Equatable, Sendable {
        var absolute: Double
        /// Fraction of |median|.
        var relative: Double

        func apply(_ sigma: Double, median: Double) -> Double {
            max(sigma, absolute, relative * abs(median))
        }

        // Per-metric floors (choices, algorithm v1):
        /// Resting HR: 1.5 bpm or 3%.
        static let restingHR = Floor(absolute: 1.5, relative: 0.03)
        /// HRV (RMSSD): 3 ms or 8%; nightly RMSSD swings more than resting HR.
        static let hrv = Floor(absolute: 3, relative: 0.08)
        /// Sleep score: 5 points.
        static let sleepScore = Floor(absolute: 5, relative: 0)
        /// Strain: 1.5 on the 0-21 scale.
        static let strain = Floor(absolute: 1.5, relative: 0)
        static let zero = Floor(absolute: 0, relative: 0)
    }

    let median: Double
    let mad: Double
    let sigma: Double
    /// Valid days used.
    let count: Int

    var status: Status { count < 3 ? .calibrating : (count < 7 ? .low : .normal) }

    /// Standard score of `value`; higher means above the personal normal.
    func z(_ value: Double) -> Double { (value - median) / sigma }

    /// `values`: previous valid days, most recent first (only the first 14 are used).
    /// Nil when there is none.
    static func compute(_ values: [Double], floor: Floor) -> Baseline? {
        let used = Array(values.filter { $0.isFinite }.prefix(window))
        guard let median = Stats.median(used) else { return nil }
        let mad = Stats.median(used.map { abs($0 - median) }) ?? 0
        let sigma = floor.apply(1.4826 * mad, median: median)
        return Baseline(median: median, mad: mad, sigma: max(sigma, 1e-9), count: used.count)
    }
}
