import SwiftUI

/// A slider over a few named stops ("Off, 100 … 150 bpm"): 2pt track, a tick per stop, a 24pt
/// thumb and a caption under each stop. Drag or tap snaps to a stop with a selection haptic;
/// VoiceOver adjusts it like a stepper. At large text the captions thin to first/middle/last.
struct SnapSlider<Value: Hashable>: View {
    let title: String
    let stops: [Value]
    @Binding var selection: Value
    let label: (Value) -> String
    var showsHeader = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var scaledThumb: CGFloat = FBSize.sliderThumb
    private var thumb: CGFloat { min(scaledThumb, 32) }

    init(_ title: String, stops: [Value], selection: Binding<Value>, showsHeader: Bool = true,
         label: @escaping (Value) -> String) {
        self.title = title
        self.stops = stops
        _selection = selection
        self.showsHeader = showsHeader
        self.label = label
    }

    private var index: Int { stops.firstIndex(of: selection) ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .textStyle(.body)
                        .foregroundStyle(.textPrimary)
                    Spacer(minLength: FBSpace.xs)
                    Text(label(selection))
                        .textStyle(.figureS)
                        .foregroundStyle(.textPrimary)
                }
            }
            GeometryReader { proxy in
                let width = proxy.size.width
                track(width: width)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { select(at: $0.location.x, width: width) }
                    )
            }
            .frame(height: FBSize.minTarget)
            captions
        }
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(label(selection))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: if index < stops.count - 1 { selection = stops[index + 1] }
            case .decrement: if index > 0 { selection = stops[index - 1] }
            @unknown default: break
            }
        }
    }

    private func x(for i: Int, width: CGFloat) -> CGFloat {
        guard stops.count > 1 else { return thumb / 2 }
        return thumb / 2 + (width - thumb) * CGFloat(i) / CGFloat(stops.count - 1)
    }

    private func select(at location: CGFloat, width: CGFloat) {
        guard isEnabled, stops.count > 1 else { return }
        let f = (location - thumb / 2) / max(1, width - thumb)
        let i = Int((f * CGFloat(stops.count - 1)).rounded())
        let clamped = min(max(i, 0), stops.count - 1)
        if stops[clamped] != selection { selection = stops[clamped] }
    }

    private func track(width: CGFloat) -> some View {
        let mid = FBSize.minTarget / 2
        let thumbX = x(for: index, width: width)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.hairlineStrong)
                .frame(width: width - thumb, height: FBStroke.sliderTrack)
                .offset(x: thumb / 2, y: mid - FBStroke.sliderTrack / 2)
            Rectangle()
                .fill(isEnabled ? Color.textPrimary : Color.textTertiary)
                .frame(width: max(0, thumbX - thumb / 2), height: FBStroke.sliderTrack)
                .offset(x: thumb / 2, y: mid - FBStroke.sliderTrack / 2)
            ForEach(stops.indices, id: \.self) { i in
                Rectangle()
                    .fill(i <= index ? Color.textPrimary : Color.hairlineStrong)
                    .frame(width: FBStroke.notch, height: 8)
                    .offset(x: x(for: i, width: width) - FBStroke.notch / 2, y: mid - 4)
            }
            Circle()
                .fill(isEnabled ? Color.textPrimary : Color.textTertiary)
                .overlay(Circle().stroke(.surface, lineWidth: FBStroke.gap))
                .frame(width: thumb, height: thumb)
                .offset(x: thumbX - thumb / 2, y: mid - thumb / 2)
        }
        .frame(width: width, height: FBSize.minTarget, alignment: .topLeading)
        .fbStateAnimation(index)
    }

    /// Captions under each stop; first and last align to the ends so nothing clips.
    private var captions: some View {
        let shown: Set<Int> = {
            guard dynamicTypeSize >= .xxLarge, stops.count > 3 else { return Set(stops.indices) }
            return [0, stops.count / 2, stops.count - 1]
        }()
        let current = index
        let last = stops.count - 1
        let bold = legibilityWeight == .bold
        return Canvas { context, size in
            for i in stops.indices where shown.contains(i) {
                let text = Text(label(stops[i]))
                    .font(.fb(.caption, bold: bold))
                    .foregroundStyle(i == current ? Color.textPrimary : Color.textSecondary)
                let anchor: UnitPoint = i == 0 ? .topLeading : i == last ? .topTrailing : .top
                let anchorX = i == 0 ? 0 : i == last ? size.width : x(for: i, width: size.width)
                context.draw(context.resolve(text), at: CGPoint(x: anchorX, y: 0), anchor: anchor)
            }
        }
        .frame(height: captionHeight)
        .accessibilityHidden(true)
    }

    @Environment(\.legibilityWeight) private var legibilityWeight

    @ScaledMetric(relativeTo: .caption) private var captionHeight: CGFloat = 16
}

#Preview("SnapSlider") {
    FBPreviewMatrix {
        SnapSlider("High heart rate alert", stops: [0, 100, 110, 120, 130, 140, 150], selection: .constant(120)) {
            $0 == 0 ? "Off" : "\($0)"
        }
    }
}
