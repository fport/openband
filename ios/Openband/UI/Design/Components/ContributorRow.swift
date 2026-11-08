import SwiftUI

/// What moved a score: name and value on top; below, a 4pt bar (primary ink) with a 2×12pt tick
/// at the usual level and a note such as "3 above usual". The bar turns to the low colour only
/// when `flagged`, and then the note says why in words.
struct ContributorRow: View {
    let name: String
    /// Formatted value ("58 bpm", "72", "96%"); nil shows "–".
    let value: String?
    /// Bar fill, 0...1. Nil hides the bar.
    var fraction: Double?
    /// Where the usual value sits on the bar, 0...1.
    var baseline: Double?
    /// "3 above usual", "Usual".
    var note: String?
    var flagged = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Every row's bar gets the same length, so equal fractions look equal down the card.
    @ScaledMetric(relativeTo: .subheadline) private var noteWidth: CGFloat = 116

    var body: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: FBSpace.xs) {
                Text(name)
                    .textStyle(.body)
                    .foregroundStyle(.textPrimary)
                Spacer(minLength: FBSpace.xs)
                Text(value ?? "–")
                    .textStyle(.figureS)
                    .foregroundStyle(value == nil ? Color.textTertiary : Color.textPrimary)
            }
            if fraction == nil, note != nil {
                noteText
            } else if fraction != nil {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: FBSpace.xxs) {
                        bar
                        noteText
                    }
                } else {
                    HStack(spacing: FBSpace.s) {
                        bar
                        noteText
                            .frame(width: noteWidth, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.vertical, FBSpace.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue([value ?? String(localized: "No data"), note].compactMap { $0 }.joined(separator: ", "))
    }

    @ViewBuilder private var bar: some View {
        if let fraction {
            Canvas { context, size in
                let barHeight = FBStroke.contributorBar
                let y = (size.height - barHeight) / 2
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: barHeight)), with: .color(.hairlineStrong))
                let filled = size.width * min(max(fraction, 0), 1)
                context.fill(Path(CGRect(x: 0, y: y, width: filled, height: barHeight)),
                             with: .color(flagged ? .low : .textPrimary))
                if let baseline {
                    let x = min(max(size.width * baseline, 1), size.width - 1)
                    // Surface gap on both sides so the tick reads over the fill.
                    context.fill(Path(CGRect(x: x - 1 - FBStroke.gap, y: 0, width: CGFloat(2) + FBStroke.gap * 2, height: size.height)),
                                 with: .color(.surface))
                    context.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(.textSecondary))
                }
            }
            .frame(height: 12)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var noteText: some View {
        if let note {
            HStack(spacing: FBSpace.xxs) {
                if flagged {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.low)
                }
                Text(note)
                    .textStyle(.subhead)
                    .foregroundStyle(flagged ? Color.textPrimary : Color.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
            }
        }
    }
}

#Preview("ContributorRow") {
    FBPreviewMatrix {
        Card {
            VStack(spacing: 0) {
                ContributorRow(name: "Resting heart rate", value: "58 bpm", fraction: 0.72, baseline: 0.6,
                               note: "3 above usual", flagged: true)
                ContributorRow(name: "Sleep score", value: "72", fraction: 0.72, baseline: 0.8, note: "8 below usual")
                ContributorRow(name: "Overnight SpO₂", value: "96%", fraction: 0.96, baseline: 0.96, note: "Usual")
                ContributorRow(name: "Previous-day strain", value: nil)
            }
        }
    }
}
