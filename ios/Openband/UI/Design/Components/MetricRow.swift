import SwiftUI

/// A change against a baseline. Deltas are neutral: same colour up or down, the arrow and the
/// words carry the direction, never red or green.
struct MetricDelta: Equatable, Sendable {
    enum Direction: Sendable { case up, down, flat }

    let direction: Direction
    /// Shown next to the arrow: "8%", "2", "12".
    let text: String

    init(_ direction: Direction, _ text: String) {
        self.direction = direction
        self.text = text
    }

    var symbol: String {
        switch direction {
        case .up: "arrow.up.right"
        case .down: "arrow.down.right"
        case .flat: "arrow.right"
        }
    }

    /// "up 8%", "down 2", "no change".
    var spoken: String {
        switch direction {
        case .up: String(localized: "up \(text)", comment: "Metric delta, e.g. up 8%")
        case .down: String(localized: "down \(text)", comment: "Metric delta, e.g. down 2")
        case .flat: String(localized: "no change", comment: "Metric delta")
        }
    }
}

/// One metric in the Home "Today" card: label, 7-day sparkline, value with unit, neutral delta
/// and a chevron. At least 52pt tall. At accessibility sizes it stacks and drops the sparkline.
/// VoiceOver reads it as one element: "Steps, 6,412, up 8% on your 7-day average".
struct MetricRow: View {
    let title: String
    /// Formatted value ("6,412", "7h 12m"); nil shows "–".
    let value: String?
    var unit: String?
    var trend: [Double?] = []
    var delta: MetricDelta?
    /// Spoken after the delta.
    var comparison: String = String(localized: "on your 7-day average", comment: "Metric delta baseline")
    var showsChevron = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var valueWidth: CGFloat = 68
    @ScaledMetric(relativeTo: .body) private var deltaWidth: CGFloat = 44

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(spacing: FBSpace.s) {
                    VStack(alignment: .leading, spacing: FBSpace.xxs) {
                        titleText
                        HStack(alignment: .firstTextBaseline, spacing: FBSpace.s) {
                            valueText
                            deltaView
                        }
                    }
                    Spacer(minLength: 0)
                    chevron
                }
                .padding(.vertical, FBSpace.s)
            } else {
                HStack(spacing: FBSpace.xs) {
                    titleText
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Sparkline(values: trend)
                    valueText
                        .frame(minWidth: valueWidth, alignment: .trailing)
                    deltaView
                        .frame(minWidth: deltaWidth, alignment: .leading)
                        .fixedSize()
                    chevron
                }
                .padding(.vertical, FBSpace.xs)
            }
        }
        .frame(minHeight: FBSize.row)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var titleText: some View {
        Text(title)
            .textStyle(.body)
            .foregroundStyle(.textPrimary)
            .lineLimit(2)
    }

    private var valueText: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value ?? "–")
                .textStyle(.figureS)
                .foregroundStyle(value == nil ? Color.textTertiary : Color.textPrimary)
            if let unit, value != nil {
                Text(unit)
                    .textStyle(.caption)
                    .foregroundStyle(.textSecondary)
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    @ViewBuilder private var deltaView: some View {
        if let delta, value != nil {
            Text("\(Image(systemName: delta.symbol)) \(delta.text)")
                .textStyle(.subhead)
                .imageScale(.small)
                .monospacedDigit()
                .foregroundStyle(.textSecondary)
            .lineLimit(1)
            .fixedSize()
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    @ViewBuilder private var chevron: some View {
        if showsChevron {
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.textTertiary)
        }
    }

    private var accessibilityText: String {
        var parts = [title]
        if let value {
            parts.append([value, unit].compactMap { $0 }.joined(separator: " "))
            if let delta { parts.append("\(delta.spoken) \(comparison)") }
        } else {
            parts.append(String(localized: "No data"))
        }
        return parts.joined(separator: ", ")
    }
}

#Preview("MetricRow") {
    FBPreviewMatrix {
        VStack(spacing: 0) {
            MetricRow(title: "Steps", value: "6,412", trend: [5.1, 7.2, 6.0, 8.8, 4.9, 5.9, 6.4], delta: .init(.up, "8%"))
            MetricRow(title: "Resting HR", value: "56", unit: "bpm", trend: [58, 57, 59, 57, 56, 57, 56], delta: .init(.down, "2"))
            MetricRow(title: "Blood oxygen", value: nil, unit: "%")
        }
        .padding(.horizontal, FBSpace.s)
        .fbCardBackground()
    }
}
