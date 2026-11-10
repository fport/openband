import CoreLocation
import Foundation
import HealthKit
import SwiftData

/// Workouts, out to Apple Health.
///
/// Every `HKWorkout(...)` initialiser is deprecated as of iOS 17, so this goes through
/// `HKWorkoutBuilder`: begin, add the samples that add up to the totals, add the metadata, end,
/// finish — and only then attach the route, because a route can only be tied to a workout that
/// already exists.
///
/// Permission is asked for here rather than up front: the workout types are useless until the
/// first workout is finished, and Apple's own guidance is to ask at the moment you need it.
extension AppleHealth {
    /// What a workout writes. Distance goes to the type the sport belongs to, so Health's own
    /// cycling and swimming totals are right.
    private var workoutTypes: Set<HKSampleType> {
        [HKObjectType.workoutType(), HKSeriesType.workoutRoute(),
         HKQuantityType(.activeEnergyBurned), HKQuantityType(.heartRate),
         HKQuantityType(.distanceWalkingRunning), HKQuantityType(.distanceCycling),
         HKQuantityType(.distanceSwimming)]
    }

    var canWriteWorkouts: Bool {
        store?.authorizationStatus(for: HKObjectType.workoutType()) == .sharingAuthorized
    }

    /// Shows the sheet for the workout types, once.
    @discardableResult
    func requestWorkoutAccess() async -> Bool {
        guard let store else { return false }
        do {
            try await store.requestAuthorization(toShare: workoutTypes, read: [])
        } catch {
            report(Self.message(for: error))
            return false
        }
        return canWriteWorkouts
    }

    /// Saves a finished workout and records the HealthKit id on it, so Openband can tell what
    /// it has already written. Does nothing, quietly, when the user has Health writing off.
    func save(workout: Workout, context: ModelContext) async {
        guard writeEnabled, Self.isAvailable, let store else { return }
        if !canWriteWorkouts, await requestWorkoutAccess() == false { return }

        let sport = workout.sport
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = sport.healthKit
        configuration.locationType = sport.healthKitIndoor ? .indoor : .outdoor
        if let swimming = sport.healthKitSwimmingLocation {
            configuration.swimmingLocationType = swimming
        }

        let device = device(for: workout.bandID.flatMap(band(_:)), fallbackName: "iPhone")
        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: device)
        let routeBuilder = sport.tracksLocation
            ? builder.seriesBuilder(for: HKSeriesType.workoutRoute()) as? HKWorkoutRouteBuilder
            : nil

        do {
            try await builder.beginCollection(at: workout.start)
            let samples = Self.samples(for: workout, device: device)
            if !samples.isEmpty { try await builder.addSamples(samples) }
            try await builder.addMetadata([
                HKMetadataKeyIndoorWorkout: sport.healthKitIndoor,
                HKMetadataKeyWasUserEntered: false,
                HKMetadataKeySyncIdentifier: "openband.workout.\(workout.id.uuidString)",
                // A second save of the same workout replaces the first only if its version is
                // higher, so the version moves with the save.
                HKMetadataKeySyncVersion: Int(Date().timeIntervalSince1970),
            ])

            if let routeBuilder {
                let locations = Self.locations(for: workout)
                // Insert in modest batches; one giant array is where this call falls over.
                for chunk in stride(from: 0, to: locations.count, by: 500) {
                    let slice = Array(locations[chunk ..< min(chunk + 500, locations.count)])
                    try await routeBuilder.insertRouteData(slice)
                }
            }

            try await builder.endCollection(at: workout.end)
            guard let saved = try await builder.finishWorkout() else { return }
            if let routeBuilder, sport.tracksLocation, workout.hasRoute {
                _ = try? await routeBuilder.finishRoute(with: saved, metadata: nil)
            }
            workout.healthUUID = saved.uuid.uuidString
            try? context.save()
            report(String(localized: "Saved this workout to Apple Health."))
        } catch {
            builder.discardWorkout()
            report(Self.message(for: error))
        }
    }

    /// Distance, energy and heart rate. Apple asks that a workout's samples add up to its
    /// totals, because the Move and Exercise rings are built from them.
    private nonisolated static func samples(for workout: Workout, device: HKDevice) -> [HKSample] {
        var samples: [HKSample] = []
        let sport = workout.sport
        if sport.tracksDistance, workout.distance > 0 {
            let type: HKQuantityType
            switch sport.healthKit {
            case .cycling: type = HKQuantityType(.distanceCycling)
            case .swimming: type = HKQuantityType(.distanceSwimming)
            default: type = HKQuantityType(.distanceWalkingRunning)
            }
            samples.append(HKQuantitySample(type: type,
                                            quantity: HKQuantity(unit: .meter(), doubleValue: workout.distance),
                                            start: workout.start, end: workout.end, device: device, metadata: nil))
        }
        if workout.energyKcal > 0 {
            samples.append(HKQuantitySample(type: HKQuantityType(.activeEnergyBurned),
                                            quantity: HKQuantity(unit: .kilocalorie(), doubleValue: workout.energyKcal),
                                            start: workout.start, end: workout.end, device: device, metadata: nil))
        }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        for point in workout.points where (25 ... 250).contains(Int(point.heartRate)) {
            let at = workout.start.addingTimeInterval(Double(point.offset))
            guard at >= workout.start, at <= workout.end else { continue }
            samples.append(HKQuantitySample(type: HKQuantityType(.heartRate),
                                            quantity: HKQuantity(unit: bpm, doubleValue: Double(point.heartRate)),
                                            start: at, end: at, device: device, metadata: nil))
        }
        return samples
    }

    /// The route as Core Location fixes. HealthKit keeps a subset of each one, so only what it
    /// stores is filled in.
    private nonisolated static func locations(for workout: Workout) -> [CLLocation] {
        workout.points.map { point in
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude),
                       altitude: point.altitude.isFinite ? Double(point.altitude) : 0,
                       horizontalAccuracy: 10,
                       verticalAccuracy: point.altitude.isFinite ? 10 : -1,
                       timestamp: workout.start.addingTimeInterval(Double(point.offset)))
        }
    }

    private func band(_ id: UUID) -> Band? {
        AppModel.shared?.band(id)
    }
}
