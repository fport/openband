import SwiftUI

/// Context only while it is true, like Tesla's charging card: live heart rate, charging, the
/// band vibrating, Bluetooth off. 56pt surface card: coloured glyph, figureS value, status
/// text and one trailing text button. Insert it with `.transition(.fbFade)`.
struct ContextCard: View {
    enum Kind: Sendable {
        case live, charging, finding, alert

        var systemImage: String {
            switch self {
            case .live: "heart.fill"
            case .charging: "bolt.fill"
            case .finding: "dot.radiowaves.left.and.right"
            case .alert: "exclamationmark.triangle.fill"
            }
        }

        var color: Color {
            switch self {
            case .live: .heart
            case .charging: .good
            case .finding: .activity
            case .alert: .low
            }
        }

        /// Spoken before the status so the glyph's meaning is never colour alone.
        var spokenName: String {
            switch self {
            case .live: String(localized: "Live heart rate")
            case .charging: String(localized: "Charging")
            case .finding: String(localized: "Finding band")
            case .alert: String(localized: "Alert")
            }
        }
    }

    let kind: Kind
    /// "72 bpm", "64%"; optional.
    var value: String?
    let status: String
    var actionTitle: String?
    var action: (() -> Void)?

    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 17

    var body: some View {
        HStack(spacing: FBSpace.s) {
            HStack(spacing: 12) {
                Image(systemName: kind.systemImage)
                    .font(.system(size: glyph, weight: .regular))
                    .foregroundStyle(kind.color)
                    .frame(width: glyph + 4)
                    .accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: FBSpace.xs) { valueText; statusText }
                    VStack(alignment: .leading, spacing: 0) { valueText; statusText }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel([kind.spokenName, value, status].compactMap { $0 }.joined(separator: ", "))
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.fbTertiary)
            }
        }
        .padding(.leading, FBSpace.s)
        .padding(.trailing, FBSpace.xs)
        .padding(.vertical, FBSpace.xxs)
        .frame(minHeight: FBSize.contextCard)
        .fbCardBackground()
    }

    @ViewBuilder private var valueText: some View {
        if let value {
            Text(value)
                .textStyle(.figureS)
                .foregroundStyle(.textPrimary)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var statusText: some View {
        Text(status)
            .textStyle(.subhead)
            .foregroundStyle(.textSecondary)
            .lineLimit(2)
    }
}

extension ContextCard {
    /// "72 bpm · Live · 1:34 left · Stop", counting down to `endsAt`.
    static func live(bpm: Int?, endsAt: Date, onStop: @escaping () -> Void) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let left = max(0, Int(endsAt.timeIntervalSince(timeline.date).rounded(.up)))
            let clock = String(format: "%d:%02d", left / 60, left % 60)
            ContextCard(kind: .live,
                        value: bpm.map { String(localized: "\($0) bpm") } ?? "–",
                        status: String(localized: "Live · \(clock) left", comment: "Live HR status with time left"),
                        actionTitle: String(localized: "Stop"), action: onStop)
        }
    }

    /// "64% · Charging · full in about 40 min".
    static func charging(battery: Int, minutesToFull: Int?) -> ContextCard {
        let status = minutesToFull.map { String(localized: "Charging · full in about \($0) min") } ?? String(localized: "Charging")
        return ContextCard(kind: .charging, value: battery.percentText(), status: status)
    }

    /// "Band is vibrating · Stop".
    static func finding(onStop: @escaping () -> Void) -> ContextCard {
        ContextCard(kind: .finding, status: String(localized: "Band is vibrating"),
                    actionTitle: String(localized: "Stop"), action: onStop)
    }

    /// One sentence and one action: "Bluetooth is off · Settings".
    static func alert(_ message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) -> ContextCard {
        ContextCard(kind: .alert, status: message, actionTitle: actionTitle, action: action)
    }
}

#Preview("ContextCard") {
    FBPreviewMatrix {
        ContextCard.live(bpm: 72, endsAt: .now.addingTimeInterval(94)) {}
        ContextCard.charging(battery: 64, minutesToFull: 40)
        ContextCard.finding {}
        ContextCard.alert("Bluetooth is off", actionTitle: "Settings") {}
    }
}
