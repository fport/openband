import SwiftUI

/// Minutes in one heart-rate zone. Zones run 1 (easy) to 5 (max).
struct HRZone: Identifiable, Hashable, Sendable {
    let index: Int
    let lowerBPM: Int
    /// nil for the top zone ("172+ bpm").
    let upperBPM: Int?
    let minutes: Double

    var id: Int { index }

    var rangeText: String {
        if let upperBPM { return String(localized: "\(lowerBPM)–\(upperBPM) bpm", comment: "Heart-rate zone range") }
        return String(localized: "\(lowerBPM)+ bpm", comment: "Top heart-rate zone range")
    }

    var spokenRange: String {
        if let upperBPM { return String(localized: "\(lowerBPM) to \(upperBPM) beats per minute") }
        return String(localized: "\(lowerBPM) beats per minute and above")
    }
}

/// Time in heart-rate zones: an 8pt bar split by 2pt surface gaps, then a legend row per zone
/// ("Zone 3 · 128–145 bpm · 24 min"). The low zones sit under 3:1 against the surface, so the
/// gaps and the labelled legend carry them, never colour alone.
struct ZoneBar: View {
    let zones: [HRZone]
    var showsLegend = true

    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var total: Double { zones.reduce(0) { $0 + max(0, $1.minutes) } }

    var body: some View {
        VStack(alignment: .leading, spacing: FBSpace.s) {
            bar
            if total == 0 {
                Text("No heart-rate zones for this day.")
                    .textStyle(.body)
                    .foregroundStyle(.textSecondary)
            } else if showsLegend {
                VStack(spacing: 0) {
                    ForEach(zones.sorted { $0.index > $1.index }) { zone in
                        legendRow(zone)
                    }
                }
            }
        }
    }

    private var bar: some View {
        Canvas { context, size in
            let height = FBStroke.zoneBar
            let y = (size.height - height) / 2
            let filled = zones.sorted { $0.index < $1.index }.filter { $0.minutes > 0 }
            guard total > 0, !filled.isEmpty else {
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: height)), with: .color(.hairline))
                return
            }
            let gaps = FBStroke.gap * CGFloat(filled.count - 1)
            let usable = max(0, size.width - gaps)
            var x: CGFloat = 0
            for zone in filled {
                let width = usable * CGFloat(zone.minutes / total)
                context.fill(Path(CGRect(x: x, y: y, width: width, height: height)), with: .color(.zone(zone.index)))
                x += width + FBStroke.gap
            }
        }
        .frame(height: FBStroke.zoneBar)
        .accessibilityHidden(true)
    }

    private func legendRow(_ zone: HRZone) -> some View {
        let minutes = Self.formatMinutes(zone.minutes, locale: locale)
        let stacked = dynamicTypeSize.isAccessibilitySize
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: FBSpace.xs) {
                Rectangle()
                    .fill(Color.zone(zone.index))
                    .frame(width: 8, height: 8)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] }
                Text(String(localized: "Zone \(zone.index)", comment: "Heart-rate zone name"))
                    .textStyle(.body)
                    .foregroundStyle(.textPrimary)
                if !stacked {
                    Text(zone.rangeText)
                        .textStyle(.subhead)
                        .foregroundStyle(.textSecondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                Spacer(minLength: FBSpace.xs)
                Text(minutes)
                    .textStyle(.figureS)
                    .foregroundStyle(zone.minutes > 0 ? Color.textPrimary : Color.textTertiary)
            }
            if stacked {
                Text(zone.rangeText)
                    .textStyle(.subhead)
                    .foregroundStyle(.textSecondary)
                    .padding(.leading, 8 + FBSpace.xs)
            }
        }
        .padding(.vertical, 6)
        .frame(minHeight: 32)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Zone \(zone.index)"))
        .accessibilityValue("\(zone.spokenRange), \(minutes)")
    }

    /// "24 min", "1h 12m".
    static func formatMinutes(_ minutes: Double, locale: Locale = .current) -> String {
        let whole = Int(minutes.rounded())
        if whole < 60 { return String(localized: "\(whole) min", comment: "Duration in minutes") }
        return Duration.seconds(whole * 60).formatted(.units(allowed: [.hours, .minutes], width: .fb(locale)).locale(locale))
    }
}

#Preview("ZoneBar") {
    FBPreviewMatrix {
        Card {
            ZoneBar(zones: [
                HRZone(index: 1, lowerBPM: 98, upperBPM: 115, minutes: 64),
                HRZone(index: 2, lowerBPM: 115, upperBPM: 128, minutes: 38),
                HRZone(index: 3, lowerBPM: 128, upperBPM: 145, minutes: 24),
                HRZone(index: 4, lowerBPM: 145, upperBPM: 162, minutes: 9),
                HRZone(index: 5, lowerBPM: 162, upperBPM: nil, minutes: 2),
            ])
        }
    }
}
