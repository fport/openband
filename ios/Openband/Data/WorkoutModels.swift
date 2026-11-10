import Foundation
import SwiftData

/// A workout recorded on the phone (and, later, read off the band's own workout files).
/// The route is kept packed in `routeData`; everything on top of it is derived once at save
/// time so the list and the share card never have to walk 3,000 points.
@Model
final class Workout {
    @Attribute(.unique) var id: UUID
    /// The band that was on the wrist, when one was.
    var bandID: UUID?
    /// `Sport.rawValue`.
    var sportRaw: String
    var start: Date
    var end: Date
    /// Wall-clock seconds from start to finish, pauses included.
    var elapsed: Double
    /// Seconds actually moving (WorkoutMath.movingTime).
    var moving: Double
    /// Metres.
    var distance: Double
    var energyKcal: Double
    var elevationGain: Double
    var avgHeartRate: Int?
    var maxHeartRate: Int?
    @Attribute(.externalStorage) var routeData: Data
    var note: String
    /// "phone" when the iPhone recorded it, "band" when it came off the band.
    var source: String
    /// The HKWorkout this was saved as, so a second save replaces instead of duplicating.
    var healthUUID: String?
    var createdAt: Date

    init(sport: Sport, start: Date, end: Date, bandID: UUID? = nil, source: String = "phone") {
        id = UUID()
        self.bandID = bandID
        sportRaw = sport.rawValue
        self.start = start
        self.end = end
        elapsed = end.timeIntervalSince(start)
        moving = 0
        distance = 0
        energyKcal = 0
        elevationGain = 0
        routeData = Data()
        note = ""
        self.source = source
        createdAt = Date()
    }

    var sport: Sport { Sport(rawValue: sportRaw) ?? .other }
    var points: [RoutePoint] { RouteCodec.decode(routeData) }
    var hasRoute: Bool { routeData.count >= RouteCodec.stride * 2 }
    var day: DayKey { DayKey(date: start, offsetMinutes: TimeZone.current.secondsFromGMT(for: start) / 60) }

    /// Seconds per km / per 100 m, or m/s — whichever the sport reads in. Moving time, like
    /// every other running app.
    var tempo: Double? {
        WorkoutMath.tempo(distance: distance, seconds: moving > 0 ? moving : elapsed, sport: sport)
    }

    var splits: [Split] {
        guard let target = sport.splitMetres else { return [] }
        return WorkoutMath.splits(points, target: target)
    }

    /// Fills the derived fields from the route. Call once, when the workout is finished.
    func summarise(points: [RoutePoint], heartRates: [Int], weightKg: Double) {
        routeData = RouteCodec.encode(points)
        elapsed = end.timeIntervalSince(start)
        if sport.tracksLocation, points.count > 1 {
            distance = RouteGeometry.length(points)
            moving = WorkoutMath.movingTime(points, sport: sport)
            elevationGain = RouteGeometry.elevationGain(points)
        } else {
            moving = elapsed
        }
        if !heartRates.isEmpty {
            avgHeartRate = Int((Double(heartRates.reduce(0, +)) / Double(heartRates.count)).rounded())
            maxHeartRate = heartRates.max()
        }
        if energyKcal == 0 {
            energyKcal = WorkoutMath.estimatedEnergy(sport: sport, seconds: moving > 0 ? moving : elapsed,
                                                     distance: distance, weightKg: weightKg)
        }
    }
}
