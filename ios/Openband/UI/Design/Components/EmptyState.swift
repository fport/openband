import SwiftUI

/// Left-aligned in a card: a 24pt thin icon, a headline, a sentence of body and at most one
/// secondary button. Used for "no band yet", "first sync", "calibrating 2 of 3 nights".
struct EmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = FBSize.emptyIcon

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize, weight: .thin))
                    .foregroundStyle(.textSecondary)
                    .frame(height: iconSize)
                    .padding(.bottom, FBSpace.xxs)
                    .accessibilityHidden(true)
                Text(title)
                    .textStyle(.headline)
                    .foregroundStyle(.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .textStyle(.body)
                    .foregroundStyle(.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(FBEmptyStateButtonStyle())
                        .padding(.top, FBSpace.xs)
                }
            }
        }
    }
}

/// The secondary button inside a surface card would vanish, so it steps up to raised.
private struct FBEmptyStateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textStyle(.button)
            .foregroundStyle(.textPrimary)
            .padding(.horizontal, FBSpace.m)
            .padding(.vertical, 12)
            .frame(minHeight: FBSize.button)
            .background(configuration.isPressed ? Color.hairline : Color.raised,
                        in: RoundedRectangle(cornerRadius: FBRadius.control))
            .overlay(RoundedRectangle(cornerRadius: FBRadius.control).stroke(.hairline, lineWidth: FBStroke.hairline))
            .contentShape(Rectangle())
            .fbStateAnimation(configuration.isPressed)
    }
}

#Preview("EmptyState") {
    FBPreviewMatrix {
        EmptyState(systemImage: "moon", title: "No sleep yet",
                   message: "Wear the band tonight. Your first night shows here after the morning sync.")
        EmptyState(systemImage: "applewatch.radiowaves.left.and.right", title: "Add your band",
                   message: "Openband reads the band directly. No account, nothing leaves this phone.",
                   actionTitle: "Add band") {}
    }
}
