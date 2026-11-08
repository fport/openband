import SwiftUI

/// The three sheet kinds: Action and Live open at the medium detent, Form at large.
enum FBSheetKind {
    case action, live, form

    var detents: Set<PresentationDetent> {
        switch self {
        case .action, .live: [.medium]
        case .form: [.large]
        }
    }
}

extension View {
    /// Sheet chrome: raised background, radius 12 top corners, visible drag indicator.
    /// Apply to the sheet's content.
    func fbSheet(_ kind: FBSheetKind) -> some View {
        presentationDetents(kind.detents)
            .presentationCornerRadius(FBRadius.card)
            .presentationBackground(.raised)
            .presentationDragIndicator(.visible)
    }

    /// Pins the screen's one primary action to the bottom safe area ("Save", "Send to band").
    /// `secondary` pins a surface button instead, for actions that stop rather than commit
    /// (the Live sheet's "Stop").
    func fbPinnedPrimary(_ title: String, isEnabled: Bool = true, secondary: Bool = false,
                         background: Color = .raised, action: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            Group {
                if secondary {
                    Button(title, action: action).buttonStyle(.fbSecondary(fullWidth: true))
                } else {
                    Button(title, action: action).buttonStyle(.fbPrimary)
                }
            }
                .disabled(!isEnabled)
                .padding(.horizontal, FBSpace.gutter)
                .padding(.top, FBSpace.xs)
                .padding(.bottom, FBSpace.xs)
                .background(background)
        }
    }
}

/// Sheet title on the left in headline, close button on the right.
struct SheetHeader: View {
    let title: String
    /// Defaults to dismissing the sheet.
    var onClose: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(alignment: .center, spacing: FBSpace.s) {
            Text(title)
                .textStyle(.headline)
                .foregroundStyle(.textPrimary)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
            CloseButton {
                if let onClose { onClose() } else { dismiss() }
            }
        }
        .padding(.leading, FBSpace.gutter)
        .padding(.trailing, FBSpace.gutter - 7)
        .padding(.top, FBSpace.m)
        .padding(.bottom, FBSpace.xs)
    }
}

/// 30pt circle with an xmark, in a 44pt hit area.
struct CloseButton: View {
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var diameter: CGFloat = FBSize.closeButton

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.textSecondary)
                .frame(width: diameter, height: diameter)
                .background(.surface, in: Circle())
                .frame(minWidth: FBSize.minTarget, minHeight: FBSize.minTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Close"))
    }
}

#Preview("Sheet") {
    FBPreviewMatrix {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "New alarm") {}
            Text("Wakes you in light sleep.")
                .textStyle(.body)
                .foregroundStyle(.textSecondary)
                .padding(.horizontal, FBSpace.gutter)
            Button("Save") {}
                .buttonStyle(.fbPrimary)
                .padding(FBSpace.gutter)
        }
        .background(.raised, in: RoundedRectangle(cornerRadius: FBRadius.card))
    }
}
