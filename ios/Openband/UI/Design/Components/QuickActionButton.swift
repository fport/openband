import SwiftUI

/// Tesla's quick-action circle: 56pt surface circle with a 22pt light SF Symbol, caption below
/// (up to two lines) in a 76pt column. A toggle's on state inverts (primary ink fill, canvas
/// icon); it is never blue. Busy shows a spinner in place of the icon.
struct QuickActionButton: View {
    let title: String
    let systemImage: String
    /// nil for a plain action; true/false for a toggle such as Do Not Disturb.
    var isOn: Bool?
    var isBusy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title) // the style draws the circle; the label carries the caption
        }
        .buttonStyle(QuickActionStyle(systemImage: systemImage, isOn: isOn ?? false, isBusy: isBusy))
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        if isBusy { return String(localized: "In progress") }
        guard let isOn else { return "" }
        return isOn ? String(localized: "On") : String(localized: "Off")
    }
}

private struct QuickActionStyle: ButtonStyle {
    let systemImage: String
    let isOn: Bool
    let isBusy: Bool

    func makeBody(configuration: Configuration) -> some View {
        QuickActionBody(configuration: configuration, systemImage: systemImage, isOn: isOn, isBusy: isBusy)
    }

    private struct QuickActionBody: View {
        let configuration: Configuration
        let systemImage: String
        let isOn: Bool
        let isBusy: Bool
        @Environment(\.isEnabled) private var isEnabled
        @ScaledMetric(relativeTo: .body) private var circle: CGFloat = FBSize.quickAction
        @ScaledMetric(relativeTo: .body) private var column: CGFloat = FBSize.quickActionColumn
        @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = FBSize.quickActionIcon

        var body: some View {
            let circle = min(self.circle, 80)
            let column = min(self.column, 150)
            let iconSize = min(self.iconSize, 32)
            VStack(spacing: FBSpace.xs) {
                ZStack {
                    Circle().fill(fill)
                    if isBusy {
                        ProgressView()
                            .tint(isOn ? Color.canvas : Color.textPrimary)
                    } else {
                        Image(systemName: systemImage)
                            .font(.system(size: iconSize, weight: .light))
                            .foregroundStyle(iconColor)
                    }
                }
                .frame(width: circle, height: circle)
                configuration.label
                    .textStyle(.caption)
                    .foregroundStyle(isEnabled ? Color.textPrimary : Color.textTertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: column)
            .contentShape(Rectangle())
            .fbStateAnimation(isOn)
            .fbStateAnimation(configuration.isPressed)
        }

        private var fill: Color {
            if isOn { return configuration.isPressed ? .textSecondary : .textPrimary }
            return configuration.isPressed ? .hairline : .surface
        }

        private var iconColor: Color {
            guard isEnabled else { return .textTertiary }
            return isOn ? .canvas : .textPrimary
        }
    }
}

/// Four quick actions in a row; a 2×2 grid at XXL and up.
struct QuickActionRow<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize >= .xxLarge {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)],
                      spacing: FBSpace.m) { content }
        } else {
            HStack(alignment: .top, spacing: 0) {
                content.frame(maxWidth: .infinity)
            }
        }
    }
}

#Preview("QuickActionButton") {
    FBPreviewMatrix {
        QuickActionRow {
            QuickActionButton(title: "Sync", systemImage: "arrow.triangle.2.circlepath", isBusy: true) {}
            QuickActionButton(title: "Live HR", systemImage: "heart") {}
            QuickActionButton(title: "Find", systemImage: "dot.radiowaves.left.and.right") {}
            QuickActionButton(title: "Do Not Disturb", systemImage: "moon", isOn: true) {}
        }
    }
}
