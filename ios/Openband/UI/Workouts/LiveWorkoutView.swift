import SwiftData
import SwiftUI

/// The running workout. One number is big — the one the sport is about — and everything else
/// sits under it in the mono face, so a glance mid-stride lands on the right figure.
struct LiveWorkoutView: View {
    @EnvironmentObject private var recorder: WorkoutRecorder
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: AppModel
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDiscard = false
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            top
            ScrollView {
                VStack(spacing: FBSpace.l) {
                    hero
                    figures
                    if recorder.sport.tracksLocation { map }
                    if let problem = recorder.route.problem { notice(problem) }
                }
                .padding(.horizontal, FBSpace.gutter)
                .padding(.top, FBSpace.m)
                .padding(.bottom, FBSpace.l)
            }
            controls
        }
        .background(.canvas)
        .interactiveDismissDisabled(recorder.isRunning)
    }

    // MARK: top

    private var top: some View {
        HStack(spacing: FBSpace.s) {
            Chip(text: recorder.sport.name, systemImage: recorder.sport.symbol,
                 tint: .action, fill: .actionSoft)
            Spacer()
            if recorder.sport.tracksLocation { gpsState }
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.textPrimary)
                    .frame(width: FBSize.closeButton, height: FBSize.closeButton)
                    .background(.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Hide the workout"))
        }
        .padding(.horizontal, FBSpace.gutter)
        .padding(.vertical, FBSpace.s)
    }

    /// Three states only: waiting for a fix, following, and lost. More detail than that is
    /// noise to someone who is running.
    private var gpsState: some View {
        let accuracy = recorder.route.accuracy
        let colour: Color = accuracy == nil ? .textTertiary : (accuracy! <= 15 ? .good : .fair)
        let word = accuracy == nil
            ? String(localized: "Finding you")
            : (accuracy! <= 15 ? String(localized: "GPS") : String(localized: "Weak GPS"))
        return HStack(spacing: FBSpace.xxs) {
            Circle().fill(colour).frame(width: FBSize.statusGlyph, height: FBSize.statusGlyph)
            Text(word).textStyle(.caption).foregroundStyle(.textSecondary)
        }
        .fbStateAnimation(colour)
    }

    // MARK: figures

    private var hero: some View {
        VStack(spacing: FBSpace.xxs) {
            if recorder.sport.tracksDistance {
                let d = WorkoutFormat.distance(recorder.distance)
                HStack(alignment: .firstTextBaseline, spacing: FBSpace.xxs) {
                    Text(d.value)
                        .textStyle(.figureXL)
                        .foregroundStyle(.textPrimary)
                        .fbNumericTransition(recorder.distance)
                    Text(d.unit)
                        .textStyle(.headline)
                        .foregroundStyle(.textSecondary)
                }
                Text("Distance")
                    .textStyle(.caption)
                    .foregroundStyle(.textSecondary)
                    .textCase(.uppercase)
            } else {
                Text(WorkoutFormat.clock(recorder.elapsed))
                    .textStyle(.timer)
                    .foregroundStyle(.textPrimary)
                Text("Time")
                    .textStyle(.caption)
                    .foregroundStyle(.textSecondary)
                    .textCase(.uppercase)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, FBSpace.s)
        .accessibilityElement(children: .combine)
    }

    private var figures: some View {
        Card {
            HStack(spacing: 0) {
                if recorder.sport.tracksDistance {
                    StatBlock(value: WorkoutFormat.clock(recorder.elapsed), label: String(localized: "workout.time", defaultValue: "Time", comment: "How long a workout lasted, not a clock time"),
                              style: .monoM, alignment: .center)
                }
                if let tempo = WorkoutFormat.tempo(recorder.tempo, sport: recorder.sport) {
                    StatBlock(value: tempo.value, unit: tempo.unit, label: String(localized: "Pace"),
                              style: .monoM, alignment: .center)
                } else if recorder.sport.tracksDistance {
                    StatBlock(value: "—", label: String(localized: "Pace"), style: .monoM, alignment: .center)
                }
                StatBlock(value: recorder.heartRate.map(String.init) ?? "—", unit: "bpm",
                          label: String(localized: "Heart"), style: .monoM, alignment: .center,
                          tint: recorder.heartRate == nil ? .textSecondary : .heart)
            }
        }
    }

    private var map: some View {
        Card(padding: FBSpace.xs) {
            Group {
                // The map comes up with the first fix. Waiting for a route to draw means a
                // runner standing at the start line sees nothing at all.
                if recorder.route.accuracy != nil {
                    RouteMapView(points: recorder.route.points, live: true)
                        .clipShape(RoundedRectangle(cornerRadius: FBRadius.control, style: .continuous))
                } else {
                    VStack(spacing: FBSpace.xs) {
                        Image(systemName: "location")
                            .font(.system(size: FBSize.emptyIcon, weight: .thin))
                            .foregroundStyle(.textTertiary)
                        Text("Your route appears once the phone has a fix.")
                            .textStyle(.caption)
                            .foregroundStyle(.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
            .frame(height: 180)
            .frame(maxWidth: .infinity)
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text)
            .textStyle(.subhead)
            .foregroundStyle(.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: controls

    private var controls: some View {
        VStack(spacing: FBSpace.xs) {
            HStack(spacing: FBSpace.s) {
                Button(recorder.phase == .paused ? String(localized: "Resume") : String(localized: "Pause")) {
                    recorder.phase == .paused ? recorder.resume() : recorder.pause()
                }
                .buttonStyle(.fbSecondary(fullWidth: true))

                Button(String(localized: "Finish")) { Task { await finish() } }
                    .buttonStyle(.fbPrimary)
                    .disabled(saving)
            }
            Button(String(localized: "Discard")) { confirmingDiscard = true }
                .buttonStyle(.fbDestructive(fullWidth: true))
        }
        .padding(.horizontal, FBSpace.gutter)
        .padding(.top, FBSpace.s)
        .padding(.bottom, FBSpace.xs)
        .background(.canvas)
        .confirmationDialog(String(localized: "Discard this workout?"), isPresented: $confirmingDiscard,
                            titleVisibility: .visible) {
            Button(String(localized: "Discard"), role: .destructive) {
                recorder.discard()
                dismiss()
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text("Nothing is kept: not the route, not the time.")
        }
    }

    private func finish() async {
        saving = true
        defer { saving = false }
        let bandID = model.firstBandID
        let weight = Profile.load().weightKg ?? 70
        let workout = await recorder.finish(context: context, bandID: bandID, weightKg: weight)
        if let workout {
            await AppleHealth.shared.save(workout: workout, context: context)
            router.movePath = [.workout(workout.id)]
            router.tab = .move
        }
        dismiss()
    }
}
