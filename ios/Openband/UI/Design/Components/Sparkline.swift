import SwiftUI

/// A 7-day shape at row scale: 56×20, one textSecondary line and a dot on the last value.
/// Monochrome on purpose (colour is earned elsewhere) and hidden from VoiceOver: the row's
/// label already says the value and the delta. Missing days break the line.
struct Sparkline: View {
    let values: [Double?]
    var color: Color = .textSecondary

    var body: some View {
        Canvas { context, size in
            let known = values.compactMap { $0 }
            guard let lo = known.min(), let hi = known.max(), values.count > 1 else {
                // Nothing to draw: a flat hairline keeps the row's rhythm.
                var flat = Path()
                flat.move(to: CGPoint(x: 0, y: size.height / 2))
                flat.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(flat, with: .color(.hairlineStrong), lineWidth: FBStroke.hairline)
                return
            }
            let dot: CGFloat = 4
            let inset = dot / 2
            let span = hi - lo
            let step = (size.width - dot) / CGFloat(values.count - 1)
            func point(_ index: Int, _ value: Double) -> CGPoint {
                let y = span == 0 ? 0.5 : (value - lo) / span
                return CGPoint(x: inset + CGFloat(index) * step,
                               y: inset + (size.height - dot) * (1 - y))
            }
            var path = Path()
            var penDown = false
            for (index, value) in values.enumerated() {
                guard let value else { penDown = false; continue }
                let p = point(index, value)
                if penDown { path.addLine(to: p) } else { path.move(to: p) }
                penDown = true
            }
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: FBStroke.sparkline, lineCap: .round, lineJoin: .round))
            if let lastIndex = values.lastIndex(where: { $0 != nil }), let last = values[lastIndex] {
                let p = point(lastIndex, last)
                context.fill(Path(ellipseIn: CGRect(x: p.x - dot / 2, y: p.y - dot / 2, width: dot, height: dot)),
                             with: .color(color))
            }
        }
        .frame(width: FBSize.sparklineWidth, height: FBSize.sparklineHeight)
        .accessibilityHidden(true)
    }
}

#Preview("Sparkline") {
    FBPreviewMatrix {
        HStack(spacing: FBSpace.m) {
            Sparkline(values: [6.1, 7.4, 5.2, 8.8, 7.9, 6.4, 6.4])
            Sparkline(values: [58, 57, 57, 56, nil, 55, 56])
            Sparkline(values: [96, 96, 96, 96, 96, 96, 96])
            Sparkline(values: [])
        }
    }
}
