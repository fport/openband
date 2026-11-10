import Combine
import Foundation
import SwiftData
import SwiftUI
import UIKit

/// The running workout. One at a time, owned by the app so it survives leaving the Move tab.
///
/// Time is always read from the clock, never counted in ticks: a timer stops firing when the
/// app goes to the background, so a workout counted in ticks loses every minute the screen is
/// off. `elapsed` subtracts whatever was spent paused.
@MainActor
final class WorkoutRecorder: ObservableObject {
    enum Phase: Equatable { case idle, recording, paused, saving }

    @Published private(set) var phase: Phase = .idle
    @Published var sport: Sport = .run
    @Published private(set) var startedAt: Date?
    /// Ticks once a second while recording, only so the clock on screen redraws.
    @Published private(set) var now = Date()
    @Published private(set) var heartRates: [Int] = []
    @Published private(set) var lastSaved: UUID?
    /// Set when saving failed; shown on the live screen rather than swallowed.
    @Published var problem: String?

    let route = RouteRecorder()

    private var pausedAt: Date?
    private var pausedSeconds: TimeInterval = 0
    private var ticker: AnyCancellable?
    private var routeChanges: AnyCancellable?

    init() {
        // The route's own changes have to reach this object too, or the live screen never redraws.
        routeChanges = route.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var isRunning: Bool { phase == .recording || phase == .paused }

    /// Seconds since the start, minus the pauses.
    var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        let end = pausedAt ?? now
        return max(0, end.timeIntervalSince(startedAt) - pausedSeconds)
    }

    var distance: Double { sport.tracksLocation ? route.distance : 0 }

    /// Seconds per km / per 100 m, or m/s, whichever the sport reads in.
    var tempo: Double? { WorkoutMath.tempo(distance: distance, seconds: elapsed, sport: sport) }

    var heartRate: Int? { heartRates.last }

    // MARK: control

    func start(_ sport: Sport, at date: Date = Date()) {
        guard phase == .idle else { return }
        self.sport = sport
        startedAt = date
        pausedAt = nil
        pausedSeconds = 0
        heartRates = []
        problem = nil
        phase = .recording
        now = date
        if sport.tracksLocation { route.start(sport, at: date) }
        UIApplication.shared.isIdleTimerDisabled = true
        ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] date in self?.now = date }
    }

    func pause() {
        guard phase == .recording else { return }
        pausedAt = Date()
        phase = .paused
        route.pause()
    }

    func resume() {
        guard phase == .paused, let pausedAt else { return }
        pausedSeconds += Date().timeIntervalSince(pausedAt)
        self.pausedAt = nil
        phase = .recording
        route.resume()
    }

    func discard() {
        finishTracking()
        startedAt = nil
        phase = .idle
    }

    /// A heart rate from the band's live session, stamped onto the fixes that follow.
    func record(heartRate: Int) {
        guard isRunning, heartRate > 25, heartRate < 250 else { return }
        heartRates.append(heartRate)
        route.heartRate = heartRate
    }

    // MARK: finish

    /// Stores the workout and returns it, or nil when there was nothing worth keeping (under
    /// ten seconds). Writing it to Apple Health is the app's job, not the recorder's.
    @discardableResult
    func finish(context: ModelContext, bandID: UUID?, weightKg: Double) async -> Workout? {
        guard let startedAt, isRunning else { return nil }
        let end = pausedAt ?? Date()
        phase = .saving
        let points = route.points
        finishTracking()

        guard end.timeIntervalSince(startedAt) - pausedSeconds >= 10 else {
            self.startedAt = nil
            phase = .idle
            return nil
        }

        let workout = Workout(sport: sport, start: startedAt, end: end, bandID: bandID)
        workout.summarise(points: points, heartRates: heartRates, weightKg: weightKg)
        // Pauses are not time spent running; take them off the clock the summary shows.
        workout.elapsed = max(0, end.timeIntervalSince(startedAt) - pausedSeconds)
        if workout.moving > workout.elapsed { workout.moving = workout.elapsed }
        context.insert(workout)
        do {
            try context.save()
        } catch {
            problem = error.localizedDescription
        }

        lastSaved = workout.id
        self.startedAt = nil
        phase = .idle
        return workout
    }

    private func finishTracking() {
        ticker?.cancel()
        ticker = nil
        route.stop()
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
