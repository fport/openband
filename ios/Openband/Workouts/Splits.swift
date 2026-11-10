import Foundation

/// One kilometre (or 100 m in the water) of a workout.
struct Split: Equatable, Sendable, Identifiable {
    /// 1 for the first split.
    var index: Int
    /// Metres in this split; the last one is usually short.
    var distance: Double
    /// Seconds spent covering it.
    var duration: Double
    var elevationGain: Double
    /// Mean heart rate over the split, or nil when the band gave none.
    var heartRate: Int?

    var id: Int { index }
    /// Seconds per metre; compare splits with this, not with a formatted string.
    var secondsPerMetre: Double { distance > 0 ? duration / distance : 0 }
    /// A split shorter than nine tenths of the target is the tail end of the workout, not a lap.
    func isPartial(of target: Double) -> Bool { distance < target * 0.9 }
}

enum WorkoutMath {
    /// Below this, the phone is drifting on a street corner rather than moving.
    static func movingSpeedFloor(_ sport: Sport) -> Double {
        switch sport.tempo {
        case .pacePerKm: 0.5
        case .speed: 1.0
        case .pacePer100m: 0.2
        case .none: 0
        }
    }

    /// Seconds the workout was actually moving. Elapsed time counts the traffic lights; moving
    /// time does not, which is why the two pace numbers on a share card never match.
    static func movingTime(_ points: [RoutePoint], sport: Sport) -> Double {
        guard points.count > 1 else { return 0 }
        let floor = movingSpeedFloor(sport)
        var seconds = 0.0
        for (a, b) in zip(points, points.dropFirst()) {
            let dt = Double(b.offset - a.offset)
            // A gap longer than two minutes is the app having been suspended, not a stretch of
            // running; counting it as moving time would flatter every workout that got paused.
            guard dt > 0, dt <= 120 else { continue }
            if RouteGeometry.distance(a, b) / dt >= floor { seconds += dt }
        }
        return seconds
    }

    /// The route cut into splits of `target` metres. Points are walked in order and a split
    /// closes the moment the running distance crosses the target, so the boundary falls inside
    /// the segment rather than at the next fix.
    static func splits(_ points: [RoutePoint], target: Double) -> [Split] {
        guard target > 0, points.count > 1 else { return [] }
        var splits: [Split] = []
        var distance = 0.0
        var startOffset = Double(points[0].offset)
        var startAltitude = points[0].altitude
        var index = 1
        var beats: [Int] = []
        var segment: [RoutePoint] = [points[0]]

        for (a, b) in zip(points, points.dropFirst()) {
            let step = RouteGeometry.distance(a, b)
            let dt = Double(b.offset - a.offset)
            if b.heartRate > 0 { beats.append(Int(b.heartRate)) }
            segment.append(b)

            if distance + step >= target, step > 0 {
                // Land exactly on the target: interpolate the crossing inside this segment.
                let share = (target - distance) / step
                let crossing = Double(a.offset) + dt * share
                let altitude = interpolate(a.altitude, b.altitude, share)
                splits.append(Split(index: index, distance: target, duration: crossing - startOffset,
                                    elevationGain: RouteGeometry.elevationGain(segment),
                                    heartRate: beats.isEmpty ? nil : Int((Double(beats.reduce(0, +)) / Double(beats.count)).rounded())))
                index += 1
                distance = (distance + step) - target
                startOffset = crossing
                startAltitude = altitude
                beats = b.heartRate > 0 ? [Int(b.heartRate)] : []
                segment = [RoutePoint(latitude: b.latitude, longitude: b.longitude, altitude: altitude,
                                      offset: Float(crossing)), b]
            } else {
                distance += step
            }
        }

        if distance > 1, let last = points.last {
            splits.append(Split(index: index, distance: distance, duration: Double(last.offset) - startOffset,
                                elevationGain: RouteGeometry.elevationGain(segment),
                                heartRate: beats.isEmpty ? nil : Int((Double(beats.reduce(0, +)) / Double(beats.count)).rounded())))
        }
        _ = startAltitude
        return splits
    }

    private static func interpolate(_ a: Float, _ b: Float, _ share: Double) -> Float {
        guard a.isFinite, b.isFinite else { return b.isFinite ? b : a }
        return a + (b - a) * Float(share)
    }

    /// Seconds per kilometre, per 100 m or metres per second, whichever the sport reads in.
    /// Returns nil when there is not enough distance or time to say anything honest.
    static func tempo(distance: Double, seconds: Double, sport: Sport) -> Double? {
        guard distance > 10, seconds > 5 else { return nil }
        switch sport.tempo {
        case .pacePerKm: return seconds / (distance / 1_000)
        case .pacePer100m: return seconds / (distance / 100)
        case .speed: return distance / seconds
        case .none: return nil
        }
    }

    /// Active energy in kcal, from METs when the band has nothing to say. Rough on purpose: the
    /// screens label it an estimate, and a band reading always wins.
    static func estimatedEnergy(sport: Sport, seconds: Double, distance: Double, weightKg: Double) -> Double {
        let hours = seconds / 3_600
        guard hours > 0, weightKg > 0 else { return 0 }
        let speed = seconds > 0 ? distance / seconds : 0
        let met: Double
        switch sport.tempo {
        case .pacePerKm: met = max(2.5, min(16, 1.0 + speed * 3.3))
        case .speed: met = max(3.0, min(16, 1.5 + speed * 1.6))
        case .pacePer100m: met = 7.0
        case .none: met = 4.0
        }
        return met * weightKg * hours
    }
}
