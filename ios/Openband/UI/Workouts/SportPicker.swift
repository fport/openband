import SwiftUI

/// Four sports across the row and the rest behind a menu. A picker you have to read is a picker
/// you stop using, so the four that cover almost every workout stay in reach.
struct SportPicker: View {
    @Binding var selection: Sport

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            menu
        } else {
            HStack(spacing: FBSpace.xs) {
                ForEach(Sport.primary) { sport in
                    tile(sport)
                }
                moreTile
            }
        }
    }

    private func tile(_ sport: Sport) -> some View {
        Button {
            selection = sport
        } label: {
            VStack(spacing: FBSpace.xxs) {
                Image(systemName: sport.symbol)
                    .font(.system(size: 20, weight: .regular))
                Text(sport.name)
                    .textStyle(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selection == sport ? Color.onAction : Color.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(selection == sport ? Color.action : Color.surface,
                        in: RoundedRectangle(cornerRadius: FBRadius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fbStateAnimation(selection)
        .accessibilityLabel(Text(sport.name))
        .accessibilityAddTraits(selection == sport ? [.isSelected, .isButton] : .isButton)
    }

    private var moreTile: some View {
        Menu {
            Picker(String(localized: "Sport"), selection: $selection) {
                ForEach(Sport.allCases) { sport in
                    Label(sport.name, systemImage: sport.symbol).tag(sport)
                }
            }
        } label: {
            VStack(spacing: FBSpace.xxs) {
                Image(systemName: Sport.more.contains(selection) ? selection.symbol : "ellipsis")
                    .font(.system(size: 20, weight: .regular))
                Text(Sport.more.contains(selection) ? selection.name : String(localized: "More"))
                    .textStyle(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(Sport.more.contains(selection) ? Color.onAction : Color.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Sport.more.contains(selection) ? Color.action : Color.surface,
                        in: RoundedRectangle(cornerRadius: FBRadius.control, style: .continuous))
        }
        .accessibilityLabel(Text("More sports"))
    }

    private var menu: some View {
        Menu {
            Picker(String(localized: "Sport"), selection: $selection) {
                ForEach(Sport.allCases) { sport in
                    Label(sport.name, systemImage: sport.symbol).tag(sport)
                }
            }
        } label: {
            HStack(spacing: FBSpace.xs) {
                Image(systemName: selection.symbol)
                Text(selection.name).textStyle(.button)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12))
            }
            .foregroundStyle(.textPrimary)
            .padding(.horizontal, FBSpace.s)
            .frame(minHeight: FBSize.button)
            .background(.surface, in: RoundedRectangle(cornerRadius: FBRadius.control, style: .continuous))
        }
    }
}

#Preview("Sports") {
    struct Host: View {
        @State private var sport = Sport.run
        var body: some View { SportPicker(selection: $sport) }
    }
    return FBPreviewMatrix { Host() }
}
