import MapKit
import SwiftUI

/// The route on a map, framed to fit and stripped of everything a map usually shouts: no
/// traffic, no points of interest, no controls, muted terrain. The route is the subject.
///
/// `Map` is an `MKMapView` underneath, so `ImageRenderer` cannot rasterise it. The share card
/// draws the route itself (`RouteTrace`) rather than trying.
struct RouteMapView: View {
    let points: [RoutePoint]
    var interactive = false
    /// While a workout is running the camera follows the runner and the blue dot is shown,
    /// because the interesting part of the map is where you are, not where you have been.
    var live = false

    @State private var camera: MapCameraPosition = .automatic

    private var coordinates: [CLLocationCoordinate2D] {
        RouteGeometry.simplified(points, tolerance: 2)
            .map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
    }

    var body: some View {
        Map(position: $camera, interactionModes: interactive ? .all : []) {
            // A dark casing under the line keeps it readable over both parks and motorways.
            MapPolyline(coordinates: coordinates)
                .stroke(Color.canvas.opacity(0.7),
                        style: StrokeStyle(lineWidth: FBStroke.route + 4, lineCap: .round, lineJoin: .round))
            MapPolyline(coordinates: coordinates)
                .stroke(Color.action,
                        style: StrokeStyle(lineWidth: FBStroke.route, lineCap: .round, lineJoin: .round))
            if let first = coordinates.first {
                Annotation("", coordinate: first) { endDot(filled: false) }
            }
            if let last = coordinates.last, coordinates.count > 1, !live {
                Annotation("", coordinate: last) { endDot(filled: true) }
            }
            if live { UserAnnotation() }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
        .mapControlVisibility(.hidden)
        .onAppear { frame() }
        .onChange(of: points.count) { _, _ in if !live { frame() } }
        .accessibilityLabel(Text("Route map"))
    }

    private func frame() {
        camera = live ? .userLocation(followsHeading: false, fallback: .automatic)
                      : .rect(Self.fitted(coordinates))
    }

    private func endDot(filled: Bool) -> some View {
        Circle()
            .strokeBorder(Color.action, lineWidth: 3)
            .background(Circle().fill(filled ? Color.action : Color.canvas))
            .frame(width: 14, height: 14)
    }

    /// The route's bounding rect with room around it. `MKPolyline` does the box (and the
    /// antimeridian); a negative inset is what expands an `MKMapRect`.
    static func fitted(_ coordinates: [CLLocationCoordinate2D], padding: Double = 0.22) -> MKMapRect {
        guard coordinates.count > 1 else { return .world }
        let rect = MKPolyline(coordinates: coordinates, count: coordinates.count).boundingMapRect
        return rect.insetBy(dx: -rect.width * padding, dy: -rect.height * padding)
    }
}
