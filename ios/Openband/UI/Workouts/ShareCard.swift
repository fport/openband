import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// The picture of a workout you would actually post: the shape of where you went, three
/// numbers, and nothing else. Drawn entirely from SwiftUI primitives, so `ImageRenderer`
/// rasterises it natively — no map tiles, no network, nothing to wait for.
///
/// It is laid out in pixels (1080 x 1080) at scale 1, and every font size is fixed: an exported
/// image must not change with the reader's Dynamic Type setting.
struct ShareCard: View {
    let workout: Workout
    /// No background at all, so the card drops straight onto someone's own photo — the one
    /// artefact in this market that people actually re-post.
    var transparent = false
    var shape: Shape = .square

    /// 1:1 for a feed post, 9:16 for a story.
    enum Shape: String, CaseIterable, Identifiable, Sendable {
        case square, story
        var id: String { rawValue }
        var size: CGSize {
            switch self {
            case .square: CGSize(width: FBSize.shareCard, height: FBSize.shareCard)
            case .story: CGSize(width: FBSize.shareCard, height: FBSize.shareCard * 16 / 9)
            }
        }
        var name: String {
            switch self {
            case .square: String(localized: "Square", comment: "Share card shape")
            case .story: String(localized: "Story", comment: "Share card shape")
            }
        }
    }

    static let side: CGFloat = FBSize.shareCard

    private var ink: Color { Color(hex: 0xF5F4EF) }
    private var muted: Color { transparent ? Color(hex: 0xF5F4EF).opacity(0.85) : Color(hex: 0xA3A49C) }
    private var pad: CGFloat { shape == .story ? 88 : 72 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            route
            figures
        }
        .frame(width: shape.size.width, height: shape.size.height, alignment: .top)
        .background(transparent ? Color.clear : Color(hex: 0x121310))
        // Over someone else's photo the only thing holding the text up is a shadow.
        .shadow(color: .black.opacity(transparent ? 0.55 : 0), radius: 14, y: 2)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: workout.sport.symbol)
                .font(.system(size: 32, weight: .medium))
            Text(workout.sport.name.uppercased())
                .font(.custom(FBTokenTable.FontName.semibold, fixedSize: 32))
            Spacer()
            Text(workout.start.formatted(date: .abbreviated, time: .shortened))
                .font(.custom(FBTokenTable.FontName.mono, fixedSize: 28))
        }
        .foregroundStyle(muted)
        .padding(.horizontal, pad)
        .padding(.top, pad)
    }

    private var route: some View {
        ZStack {
            if workout.hasRoute {
                RouteTrace(points: workout.points, tint: Color(hex: 0xFF6535), lineWidth: 16,
                           showsEnds: !transparent)
            } else {
                Image(systemName: workout.sport.symbol)
                    .font(.system(size: 220, weight: .ultraLight))
                    .foregroundStyle(Color(hex: 0xFF6535))
            }
        }
        .padding(.horizontal, pad)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var figures: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(stats, id: \.label) { stat in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(stat.value)
                                .font(.custom(FBTokenTable.FontName.semibold, fixedSize: 86))
                                .foregroundStyle(ink)
                            if let unit = stat.unit {
                                Text(unit)
                                    .font(.custom(FBTokenTable.FontName.medium, fixedSize: 30))
                                    .foregroundStyle(muted)
                            }
                        }
                        Text(stat.label.uppercased())
                            .font(.custom(FBTokenTable.FontName.mono, fixedSize: 24))
                            .foregroundStyle(muted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)

            HStack(spacing: 12) {
                OpenRing()
                    .stroke(Color(hex: 0xFF6535), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: 28, height: 28)
                Text("openband")
                    .font(.custom(FBTokenTable.FontName.medium, fixedSize: 26))
                    .foregroundStyle(muted)
            }
        }
        .padding(.horizontal, pad)
        .padding(.bottom, pad)
        .frame(width: shape.size.width, alignment: .leading)
    }

    private var stats: [(value: String, unit: String?, label: String)] {
        var out: [(String, String?, String)] = []
        if workout.sport.tracksDistance, workout.distance > 0 {
            let d = WorkoutFormat.distance(workout.distance)
            out.append((d.value, d.unit, String(localized: "Distance")))
        }
        // Moving time, which is the number every other app on the feed is showing.
        out.append((WorkoutFormat.clock(workout.moving > 0 ? workout.moving : workout.elapsed), nil,
                    String(localized: "workout.time", defaultValue: "Time", comment: "How long a workout lasted, not a clock time")))
        // A ride is remembered by how much it climbed, a run by how fast it was.
        if workout.sport.tempo == .speed, workout.elevationGain > 10 {
            let gain = WorkoutFormat.elevation(workout.elevationGain)
            out.append((gain.value, gain.unit, String(localized: "Climb")))
        } else if let tempo = WorkoutFormat.tempo(workout.tempo, sport: workout.sport) {
            out.append((tempo.value, tempo.unit, String(localized: "Pace")))
        } else if workout.energyKcal > 0 {
            out.append((WorkoutFormat.energy(workout.energyKcal), "kcal", String(localized: "Energy")))
        }
        return out
    }
}

/// Openband's mark: a ring with a gap at the top right, the way the app icon draws it.
struct OpenRing: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: min(rect.width, rect.height) / 2,
                    startAngle: .degrees(-50), endAngle: .degrees(280), clockwise: false)
        return path
    }
}

/// A rendered card, ready for the share sheet.
struct SharedWorkoutImage: Transferable {
    let image: UIImage
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { shared in
            guard let data = shared.image.pngData() else { throw CocoaError(.fileWriteUnknown) }
            return data
        }
        .suggestedFileName { "\($0.name).png" }

        // Mail, Messages and AirDrop offer themselves for files, not for raw data; without this
        // representation they are missing from the sheet.
        FileRepresentation(exportedContentType: .png) { shared in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(shared.name).png")
            try shared.image.pngData()?.write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
        .suggestedFileName { "\($0.name).png" }
    }
}

enum ShareCardRenderer {
    /// 1080 x 1080 at scale 1. `isOpaque` has to be off for the sticker, or the alpha goes.
    @MainActor
    static func render(_ workout: Workout, transparent: Bool = false,
                       shape: ShareCard.Shape = .square) -> UIImage? {
        let card = ShareCard(workout: workout, transparent: transparent, shape: shape)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 1
        renderer.isOpaque = !transparent
        renderer.proposedSize = ProposedViewSize(shape.size)
        return renderer.uiImage
    }

    static func name(_ workout: Workout) -> String {
        let day = workout.start.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
        return "openband-\(workout.sport.rawValue)-\(day)".replacingOccurrences(of: "/", with: "-")
    }
}
