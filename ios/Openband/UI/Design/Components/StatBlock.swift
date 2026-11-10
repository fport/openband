import SwiftUI

/// One figure with its unit and a word under it: 5.42 km · Distance. The unit sits on the
/// figure's baseline at caption size, which is what keeps a row of these looking like one line
/// of type rather than four.
struct StatBlock: View {
    let value: String
    var unit: String?
    let label: String
    var style: FBTextStyle = .figureM
    var alignment: HorizontalAlignment = .leading
    var tint: Color = .textPrimary

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .textStyle(style)
                    .foregroundStyle(tint)
                if let unit {
                    Text(unit)
                        .textStyle(.caption)
                        .foregroundStyle(.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            Text(label)
                .textStyle(.caption)
                .foregroundStyle(.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(label): \(value) \(unit ?? "")"))
    }
}

/// A small pill: "Run", "Personal best", "Estimate". Soft fill, never a filled accent block —
/// those are buttons.
struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color = .textSecondary
    var fill: Color = .surface

    var body: some View {
        HStack(spacing: FBSpace.xxs) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .accessibilityHidden(true)
            }
            Text(text)
                .textStyle(.caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(fill, in: Capsule())
    }
}

#Preview("Stats") {
    FBPreviewMatrix {
        Card {
            HStack(spacing: 0) {
                StatBlock(value: "5.42", unit: "km", label: "Distance")
                StatBlock(value: "28:11", label: "Time")
                StatBlock(value: "5:12", unit: "/km", label: "Pace")
            }
        }
        HStack(spacing: FBSpace.xs) {
            Chip(text: "Run", systemImage: "figure.run")
            Chip(text: "Personal best", systemImage: "trophy", tint: .action, fill: .actionSoft)
            Chip(text: "Estimate")
        }
    }
}

/// The grey chequerboard that says "this part is see-through", the way every image editor does.
struct Checkerboard: View {
    var square: CGFloat = 10

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.surface))
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = row.isMultiple(of: 2) ? 0 : square
                while x < size.width {
                    context.fill(Path(CGRect(x: x, y: y, width: square, height: square)),
                                 with: .color(.hairline))
                    x += square * 2
                }
                y += square
                row += 1
            }
        }
        .accessibilityHidden(true)
    }
}
