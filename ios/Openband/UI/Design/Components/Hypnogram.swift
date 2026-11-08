import Charts
import SwiftUI

/// Sleep stages as drawn: top to bottom Awake, REM, Light, Deep. Raw values match the band
/// parser's `SleepStage` so screens can map with `HypnogramStage(rawValue: stage.rawValue)`.
enum HypnogramStage: String, CaseIterable, Identifiable, Sendable {
    case awake, rem, light, deep

    var id: String { rawValue }

    var name: String {
        switch self {
        case .awake: String(localized: "Awake", comment: "Sleep stage")
        case .rem: String(localized: "REM", comment: "Sleep stage")
        case .light: String(localized: "Light", comment: "Sleep stage")
        case .deep: String(localized: "Deep", comment: "Sleep stage")
        }
    }

    var color: Color {
        switch self {
        case .awake: .stageAwake
        case .rem: .stageRem
        case .light: .stageLight
        case .deep: .stageDeep
        }
    }

    /// Height for Audio Graphs: awake highest, deep lowest.
    var level: Double {
        switch self {
        case .awake: 3
        case .rem: 2
        case .light: 1
        case .deep: 0
        }
    }
}

struct HypnogramSegment: Identifiable, Hashable, Sendable {
    let stage: HypnogramStage
    let start: Date
    let end: Date

    var id: Date { start }
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// One night: four 12pt rows without rounding, an x axis with only bed and wake times, and a
/// stage table below that is both the legend and the data table. VoiceOver gets the chart as
/// an Audio Graph.
struct Hypnogram: View {
    let segments: [HypnogramSegment]
    var showsTable = true

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.legibilityWeight) private var legibilityWeight
    @ScaledMetric(relativeTo: .caption) private var rowPitch: CGFloat = 22

    private var sorted: [HypnogramSegment] { segments.sorted { $0.start < $1.start } }
    private var bed: Date? { sorted.first?.start }
    private var wake: Date? { sorted.map(\.end).max() }
    private var stageNames: [String] { HypnogramStage.allCases.map(\.name) }

    var body: some View {
        VStack(alignment: .leading, spacing: FBSpace.s) {
            if let bed, let wake, wake > bed {
                chart(bed: bed, wake: wake)
                if showsTable { StageTable(segments: sorted) }
            } else {
                Text("No stages for this night.")
                    .textStyle(.body)
                    .foregroundStyle(.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: rowPitch * 4, alignment: .leading)
            }
        }
    }

    /// Stage names sit in their own column, one per 12pt row, so they never collide with the
    /// marks; the plot has a fixed height so the rows line up with the names.
    private func chart(bed: Date, wake: Date) -> some View {
        let bold = legibilityWeight == .bold
        return HStack(alignment: .top, spacing: FBSpace.xs) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(HypnogramStage.allCases) { stage in
                    Text(stage.name)
                        .font(.fb(.caption, bold: bold))
                        .foregroundStyle(.textSecondary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(height: rowPitch, alignment: .leading)
                }
            }
            .accessibilityHidden(true)
            Chart(sorted) { segment in
                RectangleMark(
                    xStart: .value("Start", segment.start),
                    xEnd: .value("End", segment.end),
                    y: .value("Stage", segment.stage.name),
                    height: .fixed(FBSize.hypnogramRow)
                )
                .foregroundStyle(by: .value("Stage", segment.stage.name))
            }
            .chartForegroundStyleScale(domain: stageNames, range: HypnogramStage.allCases.map(\.color))
            .chartLegend(.hidden)
            .chartYScale(domain: stageNames)
            .chartYAxis(.hidden)
            .chartXScale(domain: bed...wake)
            .chartXAxis {
                AxisMarks(values: [bed, wake]) { value in
                    AxisValueLabel(anchor: value.index == 0 ? .topLeading : .topTrailing) {
                        if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.hour().minute())
                                .font(.fb(.caption, bold: bold))
                                .foregroundStyle(.textSecondary)
                        }
                    }
                }
            }
            .chartPlotStyle { plot in
                plot.frame(height: rowPitch * 4)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(.hairline).frame(height: FBStroke.hairline)
                    }
            }
            .accessibilityLabel(String(localized: "Hypnogram"))
            .accessibilityChartDescriptor(self)
        }
    }
}

extension Hypnogram: AXChartDescriptorRepresentable {
    func makeChartDescriptor() -> AXChartDescriptor {
        let ordered = segments.sorted { $0.start < $1.start }
        let bed = ordered.first?.start ?? .now
        let total = max(1, (ordered.map(\.end).max() ?? bed).timeIntervalSince(bed) / 60)
        let x = AXNumericDataAxisDescriptor(title: String(localized: "Time"), range: 0...total, gridlinePositions: []) { minutes in
            bed.addingTimeInterval(minutes * 60).formatted(date: .omitted, time: .shortened)
        }
        let y = AXNumericDataAxisDescriptor(title: String(localized: "Stage"), range: 0...3, gridlinePositions: [0, 1, 2, 3]) { level in
            HypnogramStage.allCases.first { $0.level == level.rounded() }?.name ?? ""
        }
        let points = ordered.map { segment in
            AXDataPoint(x: segment.start.timeIntervalSince(bed) / 60, y: segment.stage.level,
                        label: "\(segment.stage.name), \(StageTable.format(segment.duration))")
        }
        let series = AXDataSeriesDescriptor(name: String(localized: "Sleep stages"), isContinuous: false, dataPoints: points)
        return AXChartDescriptor(title: String(localized: "Hypnogram"), summary: nil, xAxis: x, yAxis: y,
                                 additionalAxes: [], series: [series])
    }
}

/// Stage totals: swatch, name, time, a proportional bar and the share of the night.
struct StageTable: View {
    let segments: [HypnogramSegment]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    @ScaledMetric(relativeTo: .body) private var nameWidth: CGFloat = 56
    @ScaledMetric(relativeTo: .body) private var timeWidth: CGFloat = 64

    private var total: TimeInterval { segments.reduce(0) { $0 + $1.duration } }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(HypnogramStage.allCases) { stage in
                row(stage)
            }
        }
    }

    private func row(_ stage: HypnogramStage) -> some View {
        let time = segments.filter { $0.stage == stage }.reduce(0) { $0 + $1.duration }
        let share = total > 0 ? time / total : 0
        let percent = share.formatted(.percent.precision(.fractionLength(0)).locale(locale))
        let duration = Self.format(time, locale: locale)
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                // Stacked: name on one line, time and share on the next; no bar.
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: FBSpace.xs) {
                        swatch(stage)
                        Text(stage.name)
                            .textStyle(.body)
                            .foregroundStyle(.textPrimary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: FBSpace.xs) {
                        Text(duration)
                            .textStyle(.figureS)
                            .foregroundStyle(.textPrimary)
                        Text(percent)
                            .textStyle(.subhead)
                            .foregroundStyle(.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: FBSpace.xs) {
                    swatch(stage)
                    Text(stage.name)
                        .textStyle(.body)
                        .foregroundStyle(.textPrimary)
                        .frame(minWidth: nameWidth, alignment: .leading)
                    Text(duration)
                        .textStyle(.figureS)
                        .foregroundStyle(.textPrimary)
                        .frame(minWidth: timeWidth, alignment: .leading)
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(stage.color)
                            .frame(width: max(share > 0 ? 2 : 0, proxy.size.width * share), height: 4)
                            .frame(maxHeight: .infinity, alignment: .center)
                    }
                    .frame(height: 12)
                    .accessibilityHidden(true)
                    Text(percent)
                        .textStyle(.subhead)
                        .monospacedDigit()
                        .foregroundStyle(.textSecondary)
                        .frame(minWidth: 36, alignment: .trailing)
                }
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stage.name)
        .accessibilityValue("\(duration), \(percent)")
    }

    private func swatch(_ stage: HypnogramStage) -> some View {
        Rectangle()
            .fill(stage.color)
            .frame(width: 8, height: 8)
            .alignmentGuide(.firstTextBaseline) { d in d[.bottom] }
    }

    /// "1h 32m", "24m".
    static func format(_ interval: TimeInterval, locale: Locale = .current) -> String {
        Duration.seconds(Int(interval / 60) * 60).formatted(.units(allowed: [.hours, .minutes], width: .fb(locale)).locale(locale))
    }
}

#Preview("Hypnogram") {
    FBPreviewMatrix {
        Card { Hypnogram(segments: DesignSamples.night) }
        Card { Hypnogram(segments: []) }
    }
}
