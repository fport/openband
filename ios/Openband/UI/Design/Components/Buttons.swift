import SwiftUI

// v3 buttons. Blue means "press to commit": FBPrimaryButtonStyle is the only blue in the app
// (with on-state toggles). Secondary sits on surface, Tertiary is text, Destructive is
// Tertiary in the destructive colour and always confirms. 44pt tall, radius 4, 15/500 label.
// Never put filled buttons on cards.

/// Blue, white 15/500 label, 44pt, r4. One per screen, usually pinned at the bottom.
struct FBPrimaryButtonStyle: ButtonStyle {
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        FBPrimaryBody(configuration: configuration, fullWidth: fullWidth)
    }

    private struct FBPrimaryBody: View {
        let configuration: Configuration
        let fullWidth: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .textStyle(.button)
                .multilineTextAlignment(.center)
                .foregroundStyle(isEnabled ? Color.onAction : Color.textTertiary)
                .padding(.horizontal, FBSpace.m)
                .padding(.vertical, 12)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: FBSize.button)
                .background(fill, in: RoundedRectangle(cornerRadius: FBRadius.control))
                .contentShape(Rectangle())
                .fbStateAnimation(configuration.isPressed)
        }

        private var fill: Color {
            guard isEnabled else { return .surface }
            return configuration.isPressed ? .actionPressed : .action
        }
    }
}

/// Surface fill, primary text. For the second action, or the only action in an empty state.
struct FBSecondaryButtonStyle: ButtonStyle {
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        FBSecondaryBody(configuration: configuration, fullWidth: fullWidth)
    }

    private struct FBSecondaryBody: View {
        let configuration: Configuration
        let fullWidth: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .textStyle(.button)
                .multilineTextAlignment(.center)
                .foregroundStyle(isEnabled ? Color.textPrimary : Color.textTertiary)
                .padding(.horizontal, FBSpace.m)
                .padding(.vertical, 12)
                .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: FBSize.button)
                .background(configuration.isPressed ? Color.hairline : Color.surface,
                            in: RoundedRectangle(cornerRadius: FBRadius.control))
                .contentShape(Rectangle())
                .fbStateAnimation(configuration.isPressed)
        }
    }
}

/// Text only, 44pt hit target. "Skip for now", "Stop", trailing card actions.
struct FBTertiaryButtonStyle: ButtonStyle {
    var tint: Color = .textPrimary
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        FBTertiaryBody(configuration: configuration, tint: tint, fullWidth: fullWidth)
    }

    fileprivate struct FBTertiaryBody: View {
        let configuration: Configuration
        let tint: Color
        let fullWidth: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .textStyle(.button)
                .foregroundStyle(isEnabled ? tint : Color.textTertiary)
                .opacity(configuration.isPressed ? 0.6 : 1)
                // No side padding, so the label lines up with the text column; 44pt hit area.
                .frame(minWidth: FBSize.minTarget, maxWidth: fullWidth ? .infinity : nil, minHeight: FBSize.minTarget)
                .contentShape(Rectangle())
                .fbStateAnimation(configuration.isPressed)
        }
    }
}

/// Tertiary in the destructive colour. Pair it with a confirmation (see `FBDestructiveButton`).
struct FBDestructiveButtonStyle: ButtonStyle {
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        FBTertiaryButtonStyle.FBTertiaryBody(configuration: configuration, tint: .destructive, fullWidth: fullWidth)
    }
}

extension ButtonStyle where Self == FBPrimaryButtonStyle {
    static var fbPrimary: FBPrimaryButtonStyle { FBPrimaryButtonStyle() }
    static func fbPrimary(fullWidth: Bool) -> FBPrimaryButtonStyle { FBPrimaryButtonStyle(fullWidth: fullWidth) }
}

extension ButtonStyle where Self == FBSecondaryButtonStyle {
    static var fbSecondary: FBSecondaryButtonStyle { FBSecondaryButtonStyle() }
    static func fbSecondary(fullWidth: Bool) -> FBSecondaryButtonStyle { FBSecondaryButtonStyle(fullWidth: fullWidth) }
}

extension ButtonStyle where Self == FBTertiaryButtonStyle {
    static var fbTertiary: FBTertiaryButtonStyle { FBTertiaryButtonStyle() }
    static func fbTertiary(fullWidth: Bool) -> FBTertiaryButtonStyle { FBTertiaryButtonStyle(fullWidth: fullWidth) }
}

extension ButtonStyle where Self == FBDestructiveButtonStyle {
    static var fbDestructive: FBDestructiveButtonStyle { FBDestructiveButtonStyle() }
    static func fbDestructive(fullWidth: Bool) -> FBDestructiveButtonStyle { FBDestructiveButtonStyle(fullWidth: fullWidth) }
}

/// A destructive text button that asks first: "Delete alarm" → confirmation dialog.
struct FBDestructiveButton: View {
    let title: String
    var confirmTitle: String?
    var message: String?
    var fullWidth = false
    let action: () -> Void

    @State private var confirming = false

    var body: some View {
        Button(title) { confirming = true }
            .buttonStyle(.fbDestructive(fullWidth: fullWidth))
            .confirmationDialog(title, isPresented: $confirming, titleVisibility: message == nil ? .automatic : .visible) {
                Button(confirmTitle ?? title, role: .destructive, action: action)
                Button(String(localized: "Cancel"), role: .cancel) {}
            } message: {
                if let message { Text(message) }
            }
    }
}

#Preview("Buttons") {
    FBPreviewMatrix {
        VStack(alignment: .leading, spacing: FBSpace.s) {
            Button("Save") {}.buttonStyle(.fbPrimary)
            Button("Save") {}.buttonStyle(.fbPrimary).disabled(true)
            Button("Choose folder") {}.buttonStyle(.fbSecondary)
            Button("Skip for now") {}.buttonStyle(.fbTertiary)
            FBDestructiveButton(title: "Delete alarm", message: "The band stops ringing at 06:45.") {}
        }
    }
}
