import SwiftUI

/// The shape of a route, drawn from the fixes alone — no map, no tiles, no network. It is the
/// one piece of a workout that is unmistakably yours, so it carries the share card.
struct RoutePath: Shape {
    let points: [RoutePoint]
    /// Room left around the shape, as a share of the smaller side.
    var inset: CGFloat = 0.06

    func path(in rect: CGRect) -> Path {
        let unit = RouteGeometry.normalised(RouteGeometry.simplified(points))
        guard unit.count > 1 else { return Path() }
        let pad = min(rect.width, rect.height) * inset
        let box = rect.insetBy(dx: pad, dy: pad)
        let side = min(box.width, box.height)
        let originX = box.midX - side / 2
        let originY = box.midY - side / 2
        var path = Path()
        for (i, p) in unit.enumerated() {
            let point = CGPoint(x: originX + p.x * side, y: originY + p.y * side)
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

/// The route as a line, with a dot where it started and where it ended. `tint` is the line;
/// everything else is neutral so the shape, not the decoration, is what you read.
struct RouteTrace: View {
    let points: [RoutePoint]
    var tint: Color = .activity
    var lineWidth: CGFloat = FBStroke.route
    var showsEnds = true

    var body: some View {
        GeometryReader { geo in
            let unit = RouteGeometry.normalised(RouteGeometry.simplified(points))
            ZStack {
                RoutePath(points: points)
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
                if showsEnds, let first = unit.first, let last = unit.last {
                    marker(at: first, in: geo.size, filled: false)
                    marker(at: last, in: geo.size, filled: true)
                }
            }
        }
        .accessibilityLabel(Text("Route"))
    }

    private func marker(at p: (x: Double, y: Double), in size: CGSize, filled: Bool) -> some View {
        let pad = min(size.width, size.height) * 0.06
        let side = min(size.width - pad * 2, size.height - pad * 2)
        let originX = size.width / 2 - side / 2
        let originY = size.height / 2 - side / 2
        let dot = lineWidth * 1.8
        return Circle()
            .strokeBorder(tint, lineWidth: filled ? dot : lineWidth)
            .background(Circle().fill(filled ? tint : Color.canvas))
            .frame(width: dot * 2, height: dot * 2)
            .position(x: originX + p.x * side, y: originY + p.y * side)
    }
}

#Preview("Route") {
    // A rough loop, so the preview shows a shape rather than a straight line.
    let points: [RoutePoint] = (0 ..< 120).map { i in
        let t = Double(i) / 120 * 2 * .pi
        return RoutePoint(latitude: 36.88 + sin(t) * 0.012 + sin(t * 3) * 0.002,
                          longitude: 30.70 + cos(t) * 0.016,
                          altitude: Float(20 + sin(t * 2) * 8), offset: Float(i * 15))
    }
    return FBPreviewMatrix {
        Card {
            RouteTrace(points: points)
                .frame(height: 200)
        }
    }
}
