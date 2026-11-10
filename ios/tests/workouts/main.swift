import Foundation

// Hand-computed vectors for ios/Openband/Workouts (route geometry, splits, pace).
//
//   cd ios/tests/workouts
//   swiftc ../../Openband/Workouts/RouteGeometry.swift ../../Openband/Workouts/Splits.swift \
//          ../../Openband/Workouts/Sport.swift main.swift -o /tmp/workout_tests && /tmp/workout_tests
//
// Only the pure files compile here: Sport+HealthKit.swift, RouteRecorder.swift and
// WorkoutRecorder.swift need iOS frameworks and are covered by the app build.

var passed = 0
var failed = 0
var group = ""

func section(_ name: String) {
    group = name
    print("-- \(name)")
}

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok {
        passed += 1
    } else {
        failed += 1
        print("FAIL \(group) :: \(name) \(detail())")
    }
}

func near(_ name: String, _ got: Double, _ want: Double, _ tol: Double = 1e-6) {
    if abs(got - want) <= tol {
        passed += 1
    } else {
        failed += 1
        print("FAIL \(group) :: \(name) got \(got) want \(want)")
    }
}

/// One degree of latitude on the sphere the geometry uses: R x pi / 180.
let degree = RouteGeometry.earthRadius * .pi / 180

// MARK: distance

section("distance")

// Along the equator, a degree of longitude is a degree of latitude.
near("one degree of longitude at the equator",
     RouteGeometry.distance(RoutePoint(latitude: 0, longitude: 0, offset: 0),
                            RoutePoint(latitude: 0, longitude: 1, offset: 0)), degree, 1e-3)
near("one degree of latitude",
     RouteGeometry.distance(RoutePoint(latitude: 10, longitude: 30, offset: 0),
                            RoutePoint(latitude: 11, longitude: 30, offset: 0)), degree, 1e-3)
near("the same point is no distance at all",
     RouteGeometry.distance(RoutePoint(latitude: 36.88, longitude: 30.7, offset: 0),
                            RoutePoint(latitude: 36.88, longitude: 30.7, offset: 0)), 0, 1e-9)

// A straight line east along the equator, a point every 100 m, one point a minute.
let step = 100.0 / degree
let line: [RoutePoint] = (0 ... 20).map {
    RoutePoint(latitude: 0, longitude: Double($0) * step, altitude: Float(10 + $0), offset: Float($0 * 60))
}
near("length of twenty 100 m steps", RouteGeometry.length(line), 2_000, 1e-3)
near("an empty route has no length", RouteGeometry.length([]), 0)
near("one point has no length", RouteGeometry.length([line[0]]), 0)

// MARK: elevation

section("elevation")

// The line climbs 1 m per point, from 10 m to 30 m. Each step is under the 3 m threshold, so
// the climb is only counted once it has added up to more than 3: at 14, 18, 22, 26 and 30 —
// 4 m five times, which is the whole 20 m.
near("a steady 1 m per point still climbs its 20 m", RouteGeometry.elevationGain(line), 20, 1e-3)
near("noise under the threshold is not a climb",
     RouteGeometry.elevationGain([
         RoutePoint(latitude: 0, longitude: 0, altitude: 100, offset: 0),
         RoutePoint(latitude: 0, longitude: 0, altitude: 102, offset: 1),
         RoutePoint(latitude: 0, longitude: 0, altitude: 100, offset: 2),
     ]), 0, 1e-9)
near("a fix without altitude is skipped",
     RouteGeometry.elevationGain([
         RoutePoint(latitude: 0, longitude: 0, altitude: 100, offset: 0),
         RoutePoint(latitude: 0, longitude: 0, altitude: .nan, offset: 1),
         RoutePoint(latitude: 0, longitude: 0, altitude: 110, offset: 2),
     ]), 10, 1e-3)

// MARK: bounds and projection

section("projection")

let box = RouteGeometry.bounds(line)
check("bounds exist", box != nil)
near("bounds span twenty steps", (box?.maxLongitude ?? 0) - (box?.minLongitude ?? 0), 20 * step, 1e-12)

// A square in metres at latitude 60, where a degree of longitude is half a degree of latitude.
let square: [RoutePoint] = [
    RoutePoint(latitude: 60, longitude: 0, offset: 0),
    RoutePoint(latitude: 60, longitude: 2, offset: 1),
    RoutePoint(latitude: 61, longitude: 2, offset: 2),
    RoutePoint(latitude: 61, longitude: 0, offset: 3),
    RoutePoint(latitude: 60, longitude: 0, offset: 4),
]
let unit = RouteGeometry.normalised(square)
check("every point is inside the unit square", unit.allSatisfy { $0.x >= -1e-9 && $0.x <= 1 + 1e-9 && $0.y >= -1e-9 && $0.y <= 1 + 1e-9 })
// cos(60.5 degrees) is very nearly a half, so 2 degrees of longitude is about 1 of latitude:
// the shape is square in metres and must come out square, filling the box on both axes.
near("the x extent fills the box", (unit.map(\.x).max() ?? 0) - (unit.map(\.x).min() ?? 0), 0.98, 0.02)
near("the y extent fills the box", (unit.map(\.y).max() ?? 0) - (unit.map(\.y).min() ?? 0), 1, 0.02)
check("y is flipped for drawing", (unit.first?.y ?? 0) > (unit[2].y))

// MARK: simplify

section("simplify")

let simple = RouteGeometry.simplified(line, tolerance: 4)
check("a straight line collapses to its ends", simple.count == 2, "got \(simple.count)")
check("the first point survives", simple.first?.longitude == line.first?.longitude)
check("the last point survives", simple.last?.longitude == line.last?.longitude)
check("a corner survives", RouteGeometry.simplified(square, tolerance: 4).count == square.count)
check("two points are left alone", RouteGeometry.simplified(Array(line.prefix(2))).count == 2)

// MARK: codec

section("codec")

let round = RouteCodec.decode(RouteCodec.encode(line))
check("a round trip keeps every point", round.count == line.count)
check("a round trip keeps the values", round == line)
check("an empty route encodes to nothing", RouteCodec.encode([]).isEmpty)
check("a truncated blob decodes to nothing", RouteCodec.decode(Data([1, 2, 3])).isEmpty)
check("altitude survives as not-a-number",
      RouteCodec.decode(RouteCodec.encode([RoutePoint(latitude: 1, longitude: 2, offset: 3)]))[0].altitude.isNaN)

// MARK: moving time

section("moving time")

near("a steady line is all moving time", WorkoutMath.movingTime(line, sport: .run), 1_200, 1e-6)
// Two fixes in the same place: the phone sat on a wall, so none of it is moving time.
near("standing still is not moving time",
     WorkoutMath.movingTime([
         RoutePoint(latitude: 0, longitude: 0, offset: 0),
         RoutePoint(latitude: 0, longitude: 0, offset: 30),
     ], sport: .run), 0, 1e-9)
// A ten-minute gap is the app having been suspended, not a stretch of running.
near("a long gap is not counted",
     WorkoutMath.movingTime([
         RoutePoint(latitude: 0, longitude: 0, offset: 0),
         RoutePoint(latitude: 0, longitude: 10 * step, offset: 600),
     ], sport: .run), 0, 1e-9)

// MARK: splits

section("splits")

let kmSplits = WorkoutMath.splits(line, target: 1_000)
check("two kilometres make two splits", kmSplits.count == 2, "got \(kmSplits.count)")
near("the first split is a kilometre", kmSplits.first?.distance ?? 0, 1_000, 1e-6)
near("the first split takes ten minutes", kmSplits.first?.duration ?? 0, 600, 1e-3)
near("the second split takes ten minutes", kmSplits.last?.duration ?? 0, 600, 1e-3)
check("splits are numbered from one", kmSplits.first?.index == 1 && kmSplits.last?.index == 2)
check("a full split is not partial", !(kmSplits.first?.isPartial(of: 1_000) ?? true))

// Stop at 1,500 m: the tail is half a kilometre and is marked as such.
let short = Array(line.prefix(16))
let tail = WorkoutMath.splits(short, target: 1_000)
check("a part kilometre is its own split", tail.count == 2, "got \(tail.count)")
near("the tail is 500 m", tail.last?.distance ?? 0, 500, 1e-6)
check("the tail is partial", tail.last?.isPartial(of: 1_000) ?? false)
check("no splits without a target", WorkoutMath.splits(line, target: 0).isEmpty)

// MARK: tempo

section("tempo")

// 2,000 m in 1,200 s is 600 s per kilometre: a ten-minute mile pace, in round numbers.
near("pace per kilometre", WorkoutMath.tempo(distance: 2_000, seconds: 1_200, sport: .run) ?? 0, 600, 1e-9)
near("speed in metres per second", WorkoutMath.tempo(distance: 2_000, seconds: 1_200, sport: .ride) ?? 0, 5.0 / 3, 1e-9)
near("pace per hundred metres", WorkoutMath.tempo(distance: 2_000, seconds: 1_200, sport: .swim) ?? 0, 60, 1e-9)
check("strength has no tempo", WorkoutMath.tempo(distance: 2_000, seconds: 1_200, sport: .strength) == nil)
check("a few metres is not a pace", WorkoutMath.tempo(distance: 5, seconds: 1_200, sport: .run) == nil)
check("a few seconds is not a pace", WorkoutMath.tempo(distance: 2_000, seconds: 1, sport: .run) == nil)

// MARK: sports

section("sports")

check("the picker holds four sports", Sport.primary.count == 4)
check("every sport is on the picker or behind More",
      Set(Sport.primary + Sport.more) == Set(Sport.allCases))
check("a treadmill has no map", !Sport.treadmill.tracksLocation)
check("a run has a map", Sport.run.tracksLocation)
check("a pool swim splits per hundred metres", Sport.swim.splitMetres == 100)
check("a run splits per kilometre", Sport.run.splitMetres == 1_000)
check("strength has no splits", Sport.strength.splitMetres == nil)
check("strength has no distance", !Sport.strength.tracksDistance)

// MARK: energy

section("energy")

let kcal = WorkoutMath.estimatedEnergy(sport: .run, seconds: 3_600, distance: 12_000, weightKg: 70)
check("an hour of running is a few hundred kilocalories", kcal > 400 && kcal < 1_200, "got \(kcal)")
near("no time is no energy", WorkoutMath.estimatedEnergy(sport: .run, seconds: 0, distance: 0, weightKg: 70), 0)
near("no weight is no estimate", WorkoutMath.estimatedEnergy(sport: .run, seconds: 3_600, distance: 10_000, weightKg: 0), 0)

// MARK: result

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
