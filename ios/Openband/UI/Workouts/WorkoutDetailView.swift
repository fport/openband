import SwiftData
import SwiftUI

/// One workout, in the order it is asked about: where, how far and how fast, then the splits,
/// then the heart. The share card is one tap away because that is what people came for.
struct WorkoutDetailView: View {
    let workoutID: UUID

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var workouts: [Workout]
    @State private var card: SharedWorkoutImage?
    @State private var rendering = false
    @State private var transparent = false
    @State private var shape = ShareCard.Shape.square

    init(workoutID: UUID) {
        self.workoutID = workoutID
        _workouts = Query(filter: #Predicate<Workout> { $0.id == workoutID })
    }

    private var workout: Workout? { workouts.first }

    var body: some View {
        Group {
            if let workout {
                content(workout)
            } else {
                EmptyState(systemImage: "questionmark", title: String(localized: "Not here"),
                           message: String(localized: "This workout has been deleted."))
                    .padding(.horizontal, FBSpace.gutter)
            }
        }
        .fbScreen()
        .navigationTitle(workout?.sport.name ?? String(localized: "Workout"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ workout: Workout) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.l) {
                header(workout)
                if workout.hasRoute { map(workout) }
                figures(workout)
                splits(workout)
                zones(workout)
                actions(workout)
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.top, FBSpace.xs)
            .padding(.bottom, FBSpace.xl)
        }
    }

    // MARK: sections

    private func header(_ workout: Workout) -> some View {
        VStack(alignment: .leading, spacing: FBSpace.xxs) {
            Text(FBFormat.dayTitle(workout.start))
                .textStyle(.title)
                .foregroundStyle(.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(FBFormat.span(workout.start, workout.end))
                .textStyle(.monoS)
                .foregroundStyle(.textSecondary)
        }
    }

    private func map(_ workout: Workout) -> some View {
        RouteMapView(points: workout.points)
            .frame(height: 260)
            .clipShape(RoundedRectangle(cornerRadius: FBRadius.card, style: .continuous))
    }

    private func figures(_ workout: Workout) -> some View {
        VStack(spacing: FBSpace.xs) {
            Card {
                HStack(spacing: 0) {
                    if workout.sport.tracksDistance {
                        let d = WorkoutFormat.distance(workout.distance)
                        StatBlock(value: d.value, unit: d.unit, label: String(localized: "Distance"))
                    }
                    StatBlock(value: WorkoutFormat.clock(workout.elapsed), label: String(localized: "Time"))
                    if let tempo = WorkoutFormat.tempo(workout.tempo, sport: workout.sport) {
                        StatBlock(value: tempo.value, unit: tempo.unit, label: String(localized: "Pace"))
                    }
                }
            }
            Card {
                HStack(spacing: 0) {
                    StatBlock(value: WorkoutFormat.energy(workout.energyKcal), unit: "kcal",
                              label: String(localized: "Energy"), style: .figureS)
                    StatBlock(value: workout.avgHeartRate.map(String.init) ?? "—", unit: "bpm",
                              label: String(localized: "Avg heart"), style: .figureS)
                    let gain = WorkoutFormat.elevation(workout.elevationGain)
                    StatBlock(value: gain.value, unit: gain.unit, label: String(localized: "Climb"), style: .figureS)
                }
            }
            if workout.moving > 0, workout.elapsed - workout.moving > 20 {
                Footnote(String(localized: "Moving for \(WorkoutFormat.clock(workout.moving)) of \(WorkoutFormat.clock(workout.elapsed)). Pace uses moving time."))
            }
            if workout.avgHeartRate == nil {
                Footnote(String(localized: "Energy is an estimate: no heart rate was recorded. Wear the band and keep Live HR on during a workout for a real reading."))
            }
        }
    }

    @ViewBuilder private func splits(_ workout: Workout) -> some View {
        let rows = workout.splits
        if rows.count > 1 {
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: String(localized: "Splits"))
                let fastest = rows.filter { !$0.isPartial(of: workout.sport.splitMetres ?? 1_000) }
                    .min { $0.secondsPerMetre < $1.secondsPerMetre }
                Card(padding: FBSpace.s) {
                    VStack(spacing: FBSpace.xs) {
                        ForEach(rows) { split in
                            SplitRow(split: split, sport: workout.sport,
                                     slowest: rows.map(\.secondsPerMetre).max() ?? 1,
                                     isFastest: split.id == fastest?.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func zones(_ workout: Workout) -> some View {
        let zones = WorkoutZones.zones(for: workout)
        if zones.contains(where: { $0.minutes > 0 }) {
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: String(localized: "Heart-rate zones"))
                Card { ZoneBar(zones: zones) }
            }
        }
    }

    private func actions(_ workout: Workout) -> some View {
        VStack(alignment: .leading, spacing: FBSpace.s) {
            SectionHeader(title: String(localized: "Share"))
            // The card is shown before it is sent: nobody posts a picture they have not seen.
            preview
            SegmentedPicker(String(localized: "Shape"), selection: $shape, options: ShareCard.Shape.allCases) { $0.name }
            Toggle(isOn: $transparent) {
                Text("Clear background")
                    .textStyle(.subhead)
                    .foregroundStyle(.textBody)
            }
            .tint(.action)
            if let card {
                ShareLink(item: card, preview: SharePreview(card.name, image: Image(uiImage: card.image))) {
                    Text("Share the card")
                }
                .buttonStyle(.fbPrimary)
                Button(String(localized: "Copy the image")) {
                    UIPasteboard.general.image = card.image
                }
                .buttonStyle(.fbSecondary(fullWidth: true))
            }
            Footnote(String(localized: "A clear background makes a sticker you can drop onto your own photo in Instagram or wherever else."))
            FBDestructiveButton(title: String(localized: "Delete workout"),
                                message: String(localized: "It stays in Apple Health; only Openband's copy goes."),
                                fullWidth: true) {
                context.delete(workout)
                try? context.save()
                dismiss()
            }
        }
        .task(id: "\(shape.rawValue)-\(transparent)") { make(workout) }
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            // A chequerboard behind the clear card, so "clear" looks clear instead of black.
            if transparent { Checkerboard() }
            if let card {
                Image(uiImage: card.image)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: shape == .square ? 260 : 380)
        .clipShape(RoundedRectangle(cornerRadius: FBRadius.card, style: .continuous))
        .accessibilityLabel(Text("Share card preview"))
    }

    private func make(_ workout: Workout) {
        rendering = true
        card = nil
        if let image = ShareCardRenderer.render(workout, transparent: transparent, shape: shape) {
            card = SharedWorkoutImage(image: image, name: ShareCardRenderer.name(workout))
        }
        rendering = false
    }
}

/// One split: how far in, a bar for how it compares, the pace and the heart rate.
private struct SplitRow: View {
    let split: Split
    let sport: Sport
    let slowest: Double
    let isFastest: Bool

    var body: some View {
        HStack(spacing: FBSpace.s) {
            Text(WorkoutFormat.splitLabel(split, sport: sport))
                .textStyle(.monoS)
                .foregroundStyle(.textSecondary)
                .frame(width: 62, alignment: .leading)

            GeometryReader { geo in
                let share = slowest > 0 ? max(0.08, split.secondsPerMetre / slowest) : 0
                RoundedRectangle(cornerRadius: FBRadius.chart)
                    .fill(isFastest ? Color.action : Color.hairlineStrong)
                    .frame(width: geo.size.width * share, height: FBStroke.contributorBar)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: FBSize.rowIcon)

            if let tempo = WorkoutFormat.splitTempo(split, sport: sport) {
                Text(tempo.value)
                    .textStyle(.monoM)
                    .foregroundStyle(.textPrimary)
                    .frame(width: 56, alignment: .trailing)
            }
            Text(split.heartRate.map { "\($0)" } ?? "—")
                .textStyle(.monoS)
                .foregroundStyle(.textSecondary)
                .frame(width: 32, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Minutes in each heart-rate zone, from the fixes the route carries. Zone bounds follow the
/// same heart-rate reserve the Strain score uses, so a workout and a day agree.
enum WorkoutZones {
    static func zones(for workout: Workout) -> [HRZone] {
        let profile = Profile.load()
        let resting = 60.0
        let maxHR = profile.maxHR
        let bounds = Strain.zoneBounds
        func bpm(_ reserve: Double) -> Int { Int((resting + reserve * (maxHR - resting)).rounded()) }

        var minutes = [Double](repeating: 0, count: 6)
        let points = workout.points
        for (a, b) in zip(points, points.dropFirst()) where a.heartRate > 0 {
            let dt = Double(b.offset - a.offset) / 60
            guard dt > 0, dt < 1 else { continue }
            let reserve = max(0, min(1, (Double(a.heartRate) - resting) / max(1, maxHR - resting)))
            var zone = 1
            for (i, bound) in bounds.enumerated() where reserve >= bound { zone = i + 1 }
            minutes[min(5, zone)] += dt
        }
        return (1...5).map { i in
            HRZone(index: i, lowerBPM: bpm(bounds[i - 1]), upperBPM: i < 5 ? bpm(bounds[i]) : nil,
                   minutes: minutes[i])
        }
    }
}
