import Foundation

/// What the workout is. The list is deliberately short: four sports sit in the picker and the
/// rest live behind "More", because a picker you have to read is a picker you stop using.
enum Sport: String, CaseIterable, Identifiable, Codable, Sendable {
    case run, ride, swim, walk
    case trailRun, treadmill, indoorRide, openWaterSwim, hike, strength, other

    var id: String { rawValue }

    /// The four on the picker, in the order they are offered.
    static let primary: [Sport] = [.run, .ride, .swim, .walk]
    static let more: [Sport] = [.trailRun, .treadmill, .indoorRide, .openWaterSwim, .hike, .strength, .other]

    var name: String {
        switch self {
        case .run: String(localized: "Run", comment: "Sport")
        case .ride: String(localized: "Ride", comment: "Sport")
        case .swim: String(localized: "Swim", comment: "Sport")
        case .walk: String(localized: "Walk", comment: "Sport")
        case .trailRun: String(localized: "Trail run", comment: "Sport")
        case .treadmill: String(localized: "Treadmill", comment: "Sport")
        case .indoorRide: String(localized: "Indoor ride", comment: "Sport")
        case .openWaterSwim: String(localized: "Open water", comment: "Sport")
        case .hike: String(localized: "Hike", comment: "Sport")
        case .strength: String(localized: "Strength", comment: "Sport")
        case .other: String(localized: "Other", comment: "Sport")
        }
    }

    var symbol: String {
        switch self {
        case .run, .treadmill: "figure.run"
        case .trailRun: "figure.run.circle"
        case .ride, .indoorRide: "bicycle"
        case .swim, .openWaterSwim: "figure.pool.swim"
        case .walk: "figure.walk"
        case .hike: "figure.hiking"
        case .strength: "dumbbell"
        case .other: "figure.mixed.cardio"
        }
    }

    /// Indoor sports and strength have nothing to put on a map, so they never ask for location.
    var tracksLocation: Bool {
        switch self {
        case .run, .ride, .walk, .trailRun, .openWaterSwim, .hike: true
        case .treadmill, .indoorRide, .swim, .strength, .other: false
        }
    }

    /// How the sport reads its speed: runners think in minutes per kilometre, riders in km/h,
    /// swimmers in minutes per 100 m.
    enum Tempo { case pacePerKm, speed, pacePer100m, none }

    var tempo: Tempo {
        switch self {
        case .run, .walk, .trailRun, .treadmill, .hike: .pacePerKm
        case .ride, .indoorRide: .speed
        case .swim, .openWaterSwim: .pacePer100m
        case .strength, .other: .none
        }
    }

    /// Distance is meaningless for strength work; the live screen drops it.
    var tracksDistance: Bool { tempo != .none }

    /// Splits are per kilometre on land and per 100 m in the water; nil means no splits.
    var splitMetres: Double? {
        switch tempo {
        case .pacePerKm: 1_000
        case .speed: 5_000
        case .pacePer100m: 100
        case .none: nil
        }
    }
}
