import Foundation

/// Distance, pace and clock, in the units the phone's locale uses. Everything here returns the
/// number and the unit apart, so a screen can set the unit smaller than the figure.
enum WorkoutFormat {
    static var isMetric: Bool { Locale.current.measurementSystem != .us }

    /// ("5.42", "km") or ("840", "m") — and miles where the locale asks for them.
    static func distance(_ metres: Double, fraction: Int? = nil) -> (value: String, unit: String) {
        guard isMetric else {
            let miles = metres / 1_609.344
            if miles < 0.1 {
                return (FBFormat.number((metres * 3.280_84).rounded()), String(localized: "ft", comment: "Feet"))
            }
            return (FBFormat.number(miles, fraction: fraction ?? (miles >= 100 ? 0 : 2)), String(localized: "mi", comment: "Miles"))
        }
        if metres < 1_000 {
            return (FBFormat.number(metres.rounded()), String(localized: "m", comment: "Metres"))
        }
        let km = metres / 1_000
        return (FBFormat.number(km, fraction: fraction ?? (km >= 100 ? 0 : 2)), String(localized: "km", comment: "Kilometres"))
    }

    /// "5.42 km" in one piece, for a sentence or a share card.
    static func distanceText(_ metres: Double) -> String {
        let d = distance(metres)
        return "\(d.value) \(d.unit)"
    }

    /// "34:12", and "1:02:34" once it passes an hour.
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds).rounded())
        let h = total / 3_600, m = (total % 3_600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// The sport's own reading of how fast this was: ("5:12", "/km"), ("28.4", "km/h"),
    /// ("1:48", "/100 m"). nil when there is nothing honest to show yet.
    static func tempo(_ value: Double?, sport: Sport) -> (value: String, unit: String)? {
        guard let value, value.isFinite, value > 0 else { return nil }
        switch sport.tempo {
        case .pacePerKm:
            let perUnit = isMetric ? value : value * 1.609_344
            return (minutesSeconds(perUnit), isMetric ? String(localized: "/km") : String(localized: "/mi"))
        case .pacePer100m:
            return (minutesSeconds(value), String(localized: "/100 m"))
        case .speed:
            let kmh = value * 3.6
            let shown = isMetric ? kmh : kmh / 1.609_344
            return (FBFormat.number(shown, fraction: 1), isMetric ? String(localized: "km/h") : String(localized: "mph"))
        case .none:
            return nil
        }
    }

    /// Pace as "5:12"; anything over an hour per unit is not a pace, it is a stop.
    static func minutesSeconds(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0, seconds < 3_600 else { return "—" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The label a split carries: "1 km", "5 km", "100 m", and "0.６ km" for the short last one.
    static func splitLabel(_ split: Split, sport: Sport) -> String {
        guard let target = sport.splitMetres else { return "\(split.index)" }
        if split.isPartial(of: target) { return distanceText(Double(split.index - 1) * target + split.distance) }
        return distanceText(Double(split.index) * target)
    }

    /// Seconds per metre turned into the sport's tempo unit, for a split row.
    static func splitTempo(_ split: Split, sport: Sport) -> (value: String, unit: String)? {
        tempo(WorkoutMath.tempo(distance: split.distance, seconds: split.duration, sport: sport), sport: sport)
    }

    static func energy(_ kcal: Double) -> String {
        FBFormat.number(kcal.rounded())
    }

    static func elevation(_ metres: Double) -> (value: String, unit: String) {
        guard isMetric else {
            return (FBFormat.number((metres * 3.280_84).rounded()), String(localized: "ft", comment: "Feet"))
        }
        return (FBFormat.number(metres.rounded()), String(localized: "m", comment: "Metres"))
    }
}
