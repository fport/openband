import SwiftUI

/// Tesla-style segments: surface track (r4), selected segment on raised with primary text,
/// others in secondary text. 36pt visual inside a 44pt hit area; changes are colour only.
/// VoiceOver sees a standard segmented `Picker`. When the labels do not fit (large text) it
/// becomes a `Menu`.
struct SegmentedPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    /// Segments share the full width; turn off for a compact control in a header ("7d 30d 90d").
    var fillsWidth = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: String, selection: Binding<Value>, options: [Value], fillsWidth: Bool = true,
         label: @escaping (Value) -> String) {
        self.title = title
        _selection = selection
        self.options = options
        self.fillsWidth = fillsWidth
        self.label = label
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                menu
            } else {
                ViewThatFits(in: .horizontal) {
                    segments
                    menu
                }
            }
        }
    }

    private var segments: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                        .textStyle(.button)
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(selected ? Color.textPrimary : Color.textSecondary)
                        .padding(.horizontal, fillsWidth ? 12 : 10)
                        .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: FBSize.segment)
                        .background(selected ? Color.raised : Color.clear,
                                    in: RoundedRectangle(cornerRadius: FBRadius.control - 1))
                        .padding(2)
                        .frame(minHeight: FBSize.minTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 2)
        .background(
            RoundedRectangle(cornerRadius: FBRadius.control)
                .fill(.surface)
                .frame(height: FBSize.segment + 4)
        )
        .fbStateAnimation(selection)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityRepresentation {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.segmented)
        }
    }

    private var menu: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
        } label: {
            HStack(spacing: FBSpace.xs) {
                Text(title)
                    .textStyle(.body)
                    .foregroundStyle(.textSecondary)
                Spacer(minLength: FBSpace.xs)
                Text(label(selection))
                    .textStyle(.button)
                    .foregroundStyle(.textPrimary)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.textSecondary)
            }
            .padding(.horizontal, FBSpace.s)
            .padding(.vertical, FBSpace.xs)
            .frame(maxWidth: .infinity, minHeight: FBSize.minTarget)
            .background(.surface, in: RoundedRectangle(cornerRadius: FBRadius.control))
        }
        .accessibilityLabel(title)
        .accessibilityValue(label(selection))
    }
}

#Preview("SegmentedPicker") {
    FBPreviewMatrix {
        SegmentedPicker("Range", selection: .constant(7), options: [7, 30, 90]) { "\($0) days" }
        SegmentedPicker("Measure every", selection: .constant("Smart"),
                        options: ["Off", "Smart", "1 min", "10 min", "30 min"]) { $0 }
    }
}
