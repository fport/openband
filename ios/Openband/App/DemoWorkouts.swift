import Foundation
import SwiftData

/// Demo workouts and meals, for simulator screenshots and UI work. Routes are generated from a
/// seeded walk around Antalya, so every screenshot comes out the same.
enum DemoWorkouts {
    @MainActor
    static func seed(_ context: ModelContext, bandID: UUID, now: Date = Date()) {
        try? context.delete(model: Workout.self)
        try? context.delete(model: MealEntry.self)
        try? context.delete(model: BodyScan.self)

        let plan: [(Sport, Int, Double, Double)] = [
            // sport, days ago, metres, seconds
            (.run, 0, 8_240, 2_612),
            (.ride, 2, 32_600, 4_180),
            (.run, 3, 5_080, 1_584),
            (.swim, 5, 1_200, 1_740),
            (.walk, 6, 4_300, 3_120),
        ]
        for (sport, daysAgo, metres, seconds) in plan {
            let start = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)?
                .addingTimeInterval(-Double(daysAgo) * 137) ?? now
            let workout = Workout(sport: sport, start: start, end: start.addingTimeInterval(seconds), bandID: bandID)
            let points = sport.tracksLocation ? route(metres: metres, seconds: seconds, seed: UInt64(daysAgo + 1)) : []
            let beats = (0 ..< Int(seconds / 30)).map { i in
                142 + Int((sin(Double(i) / 6) * 14).rounded())
            }
            workout.summarise(points: points, heartRates: beats, weightKg: 78)
            if !sport.tracksLocation { workout.distance = metres }
            context.insert(workout)
        }

        let meals: [(String, Int, Double, Double, Double, Int)] = [
            (String(localized: "Menemen and bread"), 540, 22, 48, 28, 0),
            (String(localized: "Chicken, rice, salad"), 710, 52, 74, 18, 0),
            (String(localized: "Yoghurt and walnuts"), 260, 14, 16, 16, 1),
        ]
        for (title, kcal, protein, carbs, fat, daysAgo) in meals {
            let meal = MealEntry(eatenAt: Calendar.current.date(byAdding: .day, value: -daysAgo, to: now) ?? now,
                                 title: title, provider: "demo")
            meal.kcal = kcal
            meal.proteinGrams = protein
            meal.carbGrams = carbs
            meal.fatGrams = fat
            meal.confidence = 0.62
            context.insert(meal)
        }
        try? context.save()
    }

    /// A loop of `metres`, wobbled by a seeded generator so it looks like a street route
    /// rather than a circle, then scaled so its measured length is the length asked for.
    private static func route(metres: Double, seconds: Double, seed: UInt64) -> [RoutePoint] {
        var state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        func noise() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 33) / Double(UInt32.max) - 0.5
        }
        let count = max(80, Int(seconds / 5))
        let centreLatitude = 36.884
        let longitudeScale = 1 / cos(centreLatitude * .pi / 180)

        // A unit loop first: radius 1, with a slow wobble so it is not a circle.
        var shape: [(x: Double, y: Double)] = []
        var wobble = 0.0
        for i in 0 ..< count {
            let t = Double(i) / Double(count) * 2 * .pi
            wobble += noise() * 0.04
            let r = 1 + sin(t * 3) * 0.18 + cos(t * 5) * 0.09 + wobble * 0.5
            shape.append((cos(t) * r * 1.3, sin(t) * r))
        }

        // Walk the shape at a constant speed, so the demo's splits are the even ones a
        // steady runner would post rather than an artefact of how the loop was drawn.
        var lengths: [Double] = [0]
        for (a, b) in zip(shape, shape.dropFirst()) {
            lengths.append(lengths.last! + hypot(b.x - a.x, b.y - a.y))
        }
        let total = lengths.last ?? 1
        var even: [(x: Double, y: Double)] = []
        for i in 0 ..< count {
            let want = total * Double(i) / Double(count - 1)
            let j = min(shape.count - 2, max(0, (lengths.firstIndex { $0 >= want } ?? 1) - 1))
            let span = max(1e-12, lengths[j + 1] - lengths[j])
            let f = (want - lengths[j]) / span
            even.append((shape[j].x + (shape[j + 1].x - shape[j].x) * f,
                         shape[j].y + (shape[j + 1].y - shape[j].y) * f))
        }

        // Scale it to the distance asked for: measure it in degrees of latitude, where one
        // degree is about 111 km, and stretch from there.
        func points(_ scale: Double) -> [RoutePoint] {
            even.enumerated().map { i, p in
                RoutePoint(latitude: centreLatitude + p.y * scale,
                           longitude: 30.704 + p.x * scale * longitudeScale,
                           altitude: Float(18 + sin(Double(i) / Double(count) * 6 * .pi) * 22),
                           offset: Float(Double(i) / Double(count - 1) * seconds),
                           heartRate: Int16(140 + Int((sin(Double(i) / Double(count) * 8 * .pi) * 16).rounded())))
            }
        }
        let probe = points(0.01)
        let scale = 0.01 * metres / max(1, RouteGeometry.length(probe))
        return points(scale)
    }
}
