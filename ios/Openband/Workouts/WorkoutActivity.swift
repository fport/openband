import ActivityKit
import Foundation

/// What the Lock Screen and the Dynamic Island are told about the running workout.
///
/// The attributes are fixed for the life of the activity; the app pushes a new `ContentState`
/// every few seconds (`WorkoutActivityLink`). This file is compiled into the widget extension
/// as well, so it may only lean on Foundation and ActivityKit — nothing from the app's stack.
struct WorkoutActivityAttributes: ActivityAttributes {
    /// The sport, so the island has its name and symbol without asking the app again.
    var sport: Sport
    var startedAt: Date

    struct ContentState: Codable, Hashable {
        /// Seconds of workout, with the pauses already taken off.
        var elapsed: TimeInterval
        /// Metres. Zero for the sports that have nothing to measure.
        var distance: Double
        /// The sport's own tempo (seconds per km, seconds per 100 m, or m/s); nil until there
        /// is enough distance to divide by.
        var tempo: Double?
        var heartRate: Int?
        var isPaused: Bool
        /// The instant `elapsed` was true. The clock on screen ticks by itself between pushes
        /// rather than costing an update a second, and `Text(timerInterval:)` needs a date to
        /// count from, not a number of seconds.
        var pushedAt: Date

        /// Where the clock read zero.
        var clockStart: Date { pushedAt.addingTimeInterval(-elapsed) }

        /// The range the clock counts up over. Its end only has to sit beyond now, so it is the
        /// workout so far plus half a day — no guess about how long anyone runs for.
        var clockRange: ClosedRange<Date> {
            let start = clockStart
            return start...start.addingTimeInterval(elapsed + 12 * 3_600)
        }

        /// Freezes the clock where it stood when the workout was paused.
        var pauseTime: Date? { isPaused ? pushedAt : nil }
    }
}
