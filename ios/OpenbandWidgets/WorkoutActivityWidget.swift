import ActivityKit
import SwiftUI
import WidgetKit

/// The running workout on the Lock Screen and in the Dynamic Island, so a run does not have to
/// be unlocked to be read. Same tokens, same two faces of type, same orange as the app: the
/// extension compiles the design language rather than falling back to the system's.
struct WorkoutActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            WorkoutActivityCard(sport: context.attributes.sport, state: context.state)
                .activityBackgroundTint(.canvas)
                .activitySystemActionForegroundColor(.action)
        } dynamicIsland: { context in
            let sport = context.attributes.sport
            let state = context.state
            return DynamicIsland {
                // Expanded: everything the compact pill had no room for — the sport and the
                // heart rate the band is reporting.
                DynamicIslandExpandedRegion(.leading) {
                    SportChip(sport: sport)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    HeartReadout(bpm: state.heartRate)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Figures(sport: sport, state: state)
                        .padding(.top, FBSpace.xxs)
                }
            } compactLeading: {
                Clock(state: state, font: .activityCompact)
                    .foregroundStyle(.action)
            } compactTrailing: {
                CompactTempo(sport: sport, state: state)
            } minimal: {
                // One glyph wide: the sport, in the colour that means "you, moving".
                Image(systemName: sport.symbol)
                    .foregroundStyle(.action)
            }
            .keylineTint(.action)
        }
    }
}

// MARK: Lock Screen

/// The Lock Screen card: what the sport is, the three figures, and the two buttons that mean
/// nobody has to unlock the phone to pause. It has 160 pt of height in all, which is what
/// decides every size in here.
private struct WorkoutActivityCard: View {
    let sport: Sport
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            HStack(spacing: FBSpace.xs) {
                SportChip(sport: sport)
                if state.isPaused {
                    Text("Paused")
                        .textStyle(.caption)
                        .foregroundStyle(.textSecondary)
                        .textCase(.uppercase)
                }
                Spacer(minLength: 0)
                HeartReadout(bpm: state.heartRate)
            }
            Figures(sport: sport, state: state)
            controls
        }
        .padding(.horizontal, FBSpace.s)
        .padding(.vertical, FBSpace.xs)
    }

    /// Pause and Finish as App Intents: iOS runs them inside the app, which is where the
    /// recorder is, without ever bringing it to the front.
    private var controls: some View {
        HStack(spacing: FBSpace.xs) {
            Button(intent: PauseWorkoutIntent()) {
                Text(state.isPaused ? String(localized: "Resume") : String(localized: "Pause"))
                    .textStyle(.button)
                    .foregroundStyle(.action)
                    .frame(maxWidth: .infinity, minHeight: Self.control)
                    .background(.actionSoft, in: RoundedRectangle(cornerRadius: FBRadius.control))
            }
            Button(intent: FinishWorkoutIntent()) {
                Text("Finish")
                    .textStyle(.button)
                    .foregroundStyle(.onAction)
                    .frame(maxWidth: .infinity, minHeight: Self.control)
                    .background(.action, in: RoundedRectangle(cornerRadius: FBRadius.control))
            }
        }
        .buttonStyle(.plain)
    }

    /// Shorter than the app's 52 pt button and still over the 44 pt a thumb needs, because the
    /// card has the figures to hold as well.
    private static let control: CGFloat = FBSize.minTarget
}

// MARK: pieces

/// The three figures, in the order a glance mid-stride wants them: how long, how far, how fast.
/// Strength and "Other" have no distance to show, so they get the clock on its own.
private struct Figures: View {
    let sport: Sport
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: FBSpace.s) {
            Figure(label: String(localized: "Time")) {
                Clock(state: state, font: .activityClock)
                    .foregroundStyle(state.isPaused ? .textSecondary : .textPrimary)
            }
            if sport.tracksDistance {
                let distance = WorkoutFormat.distance(state.distance)
                Figure(label: String(localized: "Distance")) {
                    Readout(value: distance.value, unit: distance.unit)
                }
                let tempo = WorkoutFormat.tempo(state.tempo, sport: sport)
                Figure(label: String(localized: "Pace")) {
                    Readout(value: tempo?.value ?? "—", unit: tempo?.unit)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// A figure with the word for it underneath, the way the live screen sets them. The extension
/// compiles the tokens and the type scale, not the app's component library, so this is the one
/// piece of it said twice.
private struct Figure<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
            Text(label)
                .textStyle(.caption)
                .foregroundStyle(.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A number and its unit on one baseline, mono, with the unit a step smaller.
private struct Readout: View {
    let value: String
    var unit: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.activityFigure)
                .foregroundStyle(.textPrimary)
            if let unit {
                Text(unit)
                    .textStyle(.caption)
                    .foregroundStyle(.textSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// The clock, ticking on the Lock Screen's own time. `Text(timerInterval:)` counts the seconds
/// locally, so the app can push every few seconds instead of every one, and a pause freezes the
/// figure where it stood.
private struct Clock: View {
    let state: WorkoutActivityAttributes.ContentState
    let font: Font

    var body: some View {
        Text(timerInterval: state.clockRange, pauseTime: state.pauseTime, countsDown: false)
            .font(font)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

/// The compact island's trailing slot: the pace, or the sport's symbol while there is no pace
/// worth reporting yet.
private struct CompactTempo: View {
    let sport: Sport
    let state: WorkoutActivityAttributes.ContentState

    var body: some View {
        if let tempo = WorkoutFormat.tempo(state.tempo, sport: sport) {
            Text(tempo.value)
                .font(.activityCompact)
                .foregroundStyle(.textPrimary)
        } else {
            Image(systemName: sport.symbol)
                .foregroundStyle(.action)
        }
    }
}

private struct SportChip: View {
    let sport: Sport

    var body: some View {
        HStack(spacing: FBSpace.xxs) {
            Image(systemName: sport.symbol)
                .font(.system(size: 11, weight: .medium))
                .accessibilityHidden(true)
            Text(sport.name)
                .textStyle(.caption)
        }
        .foregroundStyle(.action)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.actionSoft, in: Capsule())
    }
}

/// The band's heart rate. It is the one figure here that can be missing, and a dash is more
/// honest than an empty slot.
private struct HeartReadout: View {
    let bpm: Int?

    var body: some View {
        HStack(spacing: FBSpace.xxs) {
            Image(systemName: "heart.fill")
                .font(.system(size: 11))
                .foregroundStyle(bpm == nil ? .textTertiary : .heart)
                .accessibilityHidden(true)
            Text(bpm.map(String.init) ?? "—")
                .font(.activityCompact)
                .foregroundStyle(bpm == nil ? .textSecondary : .textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Heart"))
        .accessibilityValue(bpm.map { Text("\($0) bpm") } ?? Text("—"))
    }
}

// MARK: type

private extension Font {
    /// The workout clock, cut down from the 56 pt `timer` token: a Lock Screen card has the
    /// figures and two buttons to hold inside 160 pt. It still scales with Dynamic Type, and
    /// `minimumScaleFactor` catches the largest sizes rather than letting them clip.
    static let activityClock = Font.custom(FBTextStyle.timer.fontName(), size: 30, relativeTo: .title)
        .monospacedDigit()

    /// Distance and pace beside that clock.
    static let activityFigure = Font.custom(FBTextStyle.monoM.fontName(), size: 17, relativeTo: .body)
        .monospacedDigit()

    /// The island's compact slots and the heart readout, where a figure gets about four
    /// characters of room.
    static let activityCompact = Font.custom(FBTextStyle.monoM.fontName(), size: 15, relativeTo: .caption)
        .monospacedDigit()
}
