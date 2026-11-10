import HealthKit

/// How each sport reaches Apple Health. Kept apart from `Sport` so the pure types compile
/// outside the app (ios/tests/workouts).
extension Sport {
    var healthKit: HKWorkoutActivityType {
        switch self {
        case .run, .treadmill: .running
        case .trailRun: .running
        case .ride, .indoorRide: .cycling
        case .swim, .openWaterSwim: .swimming
        case .walk: .walking
        case .hike: .hiking
        case .strength: .traditionalStrengthTraining
        case .other: .other
        }
    }

    /// Health shows indoor and outdoor runs and rides apart; swimming carries its own location type.
    var healthKitIndoor: Bool {
        switch self {
        case .treadmill, .indoorRide, .swim, .strength: true
        default: false
        }
    }

    var healthKitSwimmingLocation: HKWorkoutSwimmingLocationType? {
        switch self {
        case .swim: .pool
        case .openWaterSwim: .openWater
        default: nil
        }
    }
}
