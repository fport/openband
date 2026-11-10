import SwiftData
import SwiftUI

/// Move: pick a sport, press one button, and see what the week has added up to. Everything
/// below the button is history, which is the only thing that keeps anyone coming back.
struct WorkoutsView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var recorder: WorkoutRecorder
    @AppStorage("lastSport") private var lastSport = Sport.run.rawValue
    @Query(sort: \Workout.start, order: .reverse) private var workouts: [Workout]

    private var sport: Binding<Sport> {
        Binding(get: { Sport(rawValue: lastSport) ?? .run }, set: { lastSport = $0.rawValue })
    }

    private var week: [Workout] {
        let from = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return workouts.filter { $0.start >= from }
    }

    var body: some View {
        NavigationStack(path: $router.movePath) {
            ScrollView {
                VStack(alignment: .leading, spacing: FBSpace.l) {
                    weekSummary
                    starter
                    recent
                }
                .padding(.horizontal, FBSpace.gutter)
                .padding(.top, FBSpace.xs)
                .padding(.bottom, FBSpace.xl)
            }
            .fbScreen()
            .navigationTitle(String(localized: "Move"))
            .navigationBarTitleDisplayMode(.large)
            .routeDestinations()
        }
    }

    // MARK: this week

    private var weekSummary: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            SectionHeader(title: String(localized: "This week"),
                          trailing: week.isEmpty ? nil : String(localized: "\(week.count) workouts"))
            Card {
                HStack(spacing: FBSpace.xs) {
                    let distance = WorkoutFormat.distance(week.reduce(0) { $0 + $1.distance }, fraction: 1)
                    StatBlock(value: distance.value, unit: distance.unit, label: String(localized: "Distance"))
                    StatBlock(value: WorkoutFormat.clock(week.reduce(0) { $0 + $1.elapsed }),
                              label: String(localized: "workout.time", defaultValue: "Time", comment: "How long a workout lasted, not a clock time"))
                    StatBlock(value: WorkoutFormat.energy(week.reduce(0) { $0 + $1.energyKcal }), unit: "kcal",
                              label: String(localized: "Energy"))
                }
            }
        }
    }

    // MARK: start

    private var starter: some View {
        VStack(alignment: .leading, spacing: FBSpace.s) {
            SportPicker(selection: sport)
            Button {
                recorder.start(sport.wrappedValue)
                router.showsLiveWorkout = true
            } label: {
                Text("Start \(sport.wrappedValue.name.lowercased())")
            }
            .buttonStyle(.fbPrimary)
            .disabled(recorder.isRunning)
            if recorder.isRunning {
                Button(String(localized: "Back to the workout")) { router.showsLiveWorkout = true }
                    .buttonStyle(.fbSecondary(fullWidth: true))
            }
        }
    }

    // MARK: history

    @ViewBuilder private var recent: some View {
        if workouts.isEmpty {
            EmptyState(systemImage: "figure.run",
                       title: String(localized: "No workouts yet"),
                       message: String(localized: "Start one above. Openband follows your route on the phone and keeps it here and in Apple Health — nothing is uploaded."))
        } else {
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: String(localized: "Recent"))
                ListCard {
                    ForEach(Array(workouts.prefix(8).enumerated()), id: \.element.id) { index, workout in
                        NavigationLink(value: Route.workout(workout.id)) {
                            WorkoutRow(workout: workout, showsDivider: index < min(8, workouts.count) - 1)
                        }
                        .buttonStyle(.fbRow)
                    }
                }
                if workouts.count > 8 {
                    NavigationLink(value: Route.workoutHistory) {
                        Text("All \(workouts.count) workouts")
                    }
                    .buttonStyle(.fbTertiary)
                }
            }
        }
    }
}

/// One line of history: the shape of the route, what it was, and the two numbers that matter.
struct WorkoutRow: View {
    let workout: Workout
    var showsDivider = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: FBSpace.s) {
                Group {
                    if workout.hasRoute {
                        RouteTrace(points: workout.points, lineWidth: 2, showsEnds: false)
                    } else {
                        Image(systemName: workout.sport.symbol)
                            .font(.system(size: 18))
                            .foregroundStyle(.textSecondary)
                    }
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 1) {
                    Text(workout.sport.name)
                        .textStyle(.body)
                        .foregroundStyle(.textPrimary)
                    Text(FBFormat.shortDay(workout.start) + " · " + FBFormat.time(workout.start))
                        .textStyle(.caption)
                        .foregroundStyle(.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(workout.sport.tracksDistance && workout.distance > 0
                         ? WorkoutFormat.distanceText(workout.distance)
                         : WorkoutFormat.clock(workout.elapsed))
                        .textStyle(.figureS)
                        .foregroundStyle(.textPrimary)
                    if let tempo = WorkoutFormat.tempo(workout.tempo, sport: workout.sport) {
                        Text("\(tempo.value) \(tempo.unit)")
                            .textStyle(.monoS)
                            .foregroundStyle(.textSecondary)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, FBSpace.s)
            .padding(.vertical, FBSpace.xs)
            .frame(minHeight: FBSize.row)
            if showsDivider {
                Rectangle().fill(Color.hairline).frame(height: FBStroke.hairline)
                    .padding(.leading, FBSpace.s)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Every workout, newest first.
struct WorkoutHistoryView: View {
    @Query(sort: \Workout.start, order: .reverse) private var workouts: [Workout]

    var body: some View {
        ScrollView {
            ListCard {
                ForEach(Array(workouts.enumerated()), id: \.element.id) { index, workout in
                    NavigationLink(value: Route.workout(workout.id)) {
                        WorkoutRow(workout: workout, showsDivider: index < workouts.count - 1)
                    }
                    .buttonStyle(.fbRow)
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.xl)
        }
        .fbScreen()
        .navigationTitle(String(localized: "Workouts"))
    }
}
