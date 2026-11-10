import ActivityKit
import Foundation

/// The running workout's Live Activity: the Lock Screen and Dynamic Island copy of the figures
/// the live screen shows. `WorkoutRecorder` owns one and tells it when they moved, so everything
/// ActivityKit-shaped stays in here and nothing on screen has to know about it.
@MainActor
final class WorkoutActivityLink {
    /// ActivityKit gives each activity a budget of updates, and a workout that pushed on every
    /// tick would spend it within the first few kilometres. Three seconds is as often as a Lock
    /// Screen is worth reading anyway, and the clock on it ticks by itself in between.
    private static let minimumInterval: TimeInterval = 3

    private var activity: Activity<WorkoutActivityAttributes>?
    private var lastPush = Date.distantPast

    func start(sport: Sport, startedAt: Date, state: WorkoutActivityAttributes.ContentState) {
        // Live Activities can be switched off for the app in Settings. A workout still records;
        // it just has nothing on the Lock Screen, and that is not worth an error on screen.
        guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = WorkoutActivityAttributes(sport: sport, startedAt: startedAt)
        activity = try? Activity<WorkoutActivityAttributes>.request(attributes: attributes,
                                                                    content: content(state))
        lastPush = Date()
    }

    /// `force` is for what has to land at once — a pause, a resume — instead of waiting for the
    /// next slot.
    func update(_ state: WorkoutActivityAttributes.ContentState, force: Bool = false) {
        guard let activity else { return }
        guard force || Date().timeIntervalSince(lastPush) >= Self.minimumInterval else { return }
        lastPush = Date()
        Task { await activity.update(content(state)) }
    }

    /// Takes the activity off the Lock Screen. A finished workout opens as a summary in the app,
    /// so there is nothing left for the activity to say, and a discarded one never happened.
    func end(_ state: WorkoutActivityAttributes.ContentState) {
        guard let activity else { return }
        self.activity = nil
        lastPush = .distantPast
        Task { await activity.end(content(state), dismissalPolicy: .immediate) }
    }

    /// A Live Activity outlives the process that started it, and nothing in the recorder does.
    /// One still on the Lock Screen at launch therefore belongs to a workout that no longer
    /// exists — after a force quit, say — so it gets cleared rather than left counting, with
    /// two buttons that would drive nothing.
    func endOrphaned() {
        for orphan in Activity<WorkoutActivityAttributes>.activities {
            Task { await orphan.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// No stale date: elapsed time is read from the clock, not counted in ticks, so the figures
    /// stay true while the app is suspended and there is nothing to mark as out of date.
    private func content(_ state: WorkoutActivityAttributes.ContentState)
        -> ActivityContent<WorkoutActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: nil)
    }
}
