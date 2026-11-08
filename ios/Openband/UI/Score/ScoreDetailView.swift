import Charts
import SwiftUI

/// One template for Sleep, Recovery and Strain: a big arc, one sentence from the top
/// contributors, the contributors against their baselines, the trend and how it is calculated.
/// Strain adds its zone bar and an hourly view; Sleep adds a compact night.
struct ScoreDetailView: View {
    let kind: ScoreKind
    let day: DayKey
    let band: Band
    let history: HealthHistory

    @State private var range: TrendRange = .month

    private var value: Double? { history.score(kind, day) }
    private var result: DayScoreResult? { history.result(day) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.l) {
                VStack(alignment: .leading, spacing: FBSpace.m) {
                    Text(FBFormat.dayTitle(day.noon))
                        .textStyle(.subhead)
                        .foregroundStyle(.textSecondary)
                    HStack {
                        Spacer(minLength: 0)
                        ScoreArc(kind: kind, value: value, style: .detail)
                        Spacer(minLength: 0)
                    }
                    Text(ScoreExplainer.sentence(kind, result: result, value: value))
                        .textStyle(.body)
                        .foregroundStyle(.textBody)
                        .fixedSize(horizontal: false, vertical: true)
                    if let confidence = history.confidence(kind, day), value != nil, confidence.level < .high {
                        Label {
                            Text(confidence.level.title)
                        } icon: {
                            Image(systemName: "circle.lefthalf.filled").font(.system(size: 11))
                        }
                        .textStyle(.subhead)
                        .foregroundStyle(.textSecondary)
                    }
                }

                if kind == .strain, let strain = result?.strain {
                    strainExtras(strain)
                }

                contributors

                if kind == .sleep, let night = history.mainSleep(day), !night.hypnogramSegments.isEmpty {
                    VStack(alignment: .leading, spacing: FBSpace.xs) {
                        SectionHeader(title: String(localized: "The night"))
                        Card { Hypnogram(segments: night.hypnogramSegments, showsTable: false) }
                        ListCard {
                            NavigationLink(value: Route.night(day: day.index)) {
                                ListRow(title: String(localized: "Open night"), showsDivider: false)
                            }
                            .buttonStyle(.fbRow)
                        }
                    }
                }

                Card {
                    TrendChart(metric: kind.trendMetric, points: history.points(kind.trendMetric, ending: day), range: $range)
                }

                ListCard {
                    NavigationLink(value: Route.scoreMethod(kind, day: day.index)) {
                        ListRow(title: String(localized: "How it's calculated"), systemImage: "function", showsDivider: false)
                    }
                    .buttonStyle(.fbRow)
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.xl)
        }
        .fbScreen()
        .navigationTitle(kind.name)
        .navigationBarTitleDisplayMode(.large)
    }

    // MARK: contributors

    @ViewBuilder private var contributors: some View {
        let rows = ScoreExplainer.contributorRows(kind, result: result, day: day, history: history)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: FBSpace.xs) {
                SectionHeader(title: String(localized: "Contributors"))
                Card {
                    VStack(alignment: .leading, spacing: FBSpace.m) {
                        ForEach(rows) { row in
                            ContributorRow(name: row.name, value: row.value, fraction: row.fraction,
                                           baseline: row.baseline, note: row.note, flagged: row.flagged)
                        }
                    }
                }
            }
        }
    }

    // MARK: strain

    @ViewBuilder private func strainExtras(_ strain: StrainResult) -> some View {
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            SectionHeader(title: String(localized: "Heart-rate zones"))
            Card { ZoneBar(zones: strain.hrZones) }
        }
        VStack(alignment: .leading, spacing: FBSpace.xs) {
            SectionHeader(title: String(localized: "By hour"))
            Card { HourlyLoadChart(hourly: strain.hourlyTrimp) }
            Footnote(String(localized: "Load per hour; taller bars mean harder effort."))
        }
    }
}

extension ScoreKind {
    var trendMetric: TrendMetric {
        switch self {
        case .sleep: .sleepScore
        case .recovery: .recovery
        case .strain: .strain
        }
    }
}

extension StrainResult {
    /// Zone bounds in bpm from the reserve fractions the day was scored with.
    var hrZones: [HRZone] {
        let bounds = Strain.zoneBounds
        func bpm(_ r: Double) -> Int { Int((restingHR + r * (maxHR - restingHR)).rounded()) }
        return (1...5).map { i in
            HRZone(index: i, lowerBPM: bpm(bounds[i - 1]), upperBPM: i < 5 ? bpm(bounds[i]) : nil,
                   minutes: Double(i < zoneMinutes.count ? zoneMinutes[i] : 0))
        }
    }
}

extension SleepRecord {
    var hypnogramSegments: [HypnogramSegment] {
        StageSegment.unpack(stageTimeline).compactMap { s in
            let stage: HypnogramStage? = switch s.stage {
            case .awake: .awake
            case .light: .light
            case .deep: .deep
            case .rem: .rem
            default: nil
            }
            return stage.map { HypnogramSegment(stage: $0, start: s.start, end: s.end) }
        }
    }
}

/// Load per local hour as bars: the shape of the day, not a number to read.
struct HourlyLoadChart: View {
    let hourly: [Double]

    private struct Hour: Identifiable {
        let hour: Int
        let load: Double
        var id: Int { hour }
    }

    var body: some View {
        let hours = hourly.enumerated().map { Hour(hour: $0.offset, load: $0.element) }
        Chart(hours) { h in
            BarMark(x: .value(String(localized: "Hour"), h.hour), y: .value(String(localized: "Load"), h.load), width: .ratio(0.7))
                .foregroundStyle(.activity)
                .clipShape(RoundedRectangle(cornerRadius: FBRadius.chart))
        }
        .chartXScale(domain: -0.5...23.5)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18]) { value in
                AxisValueLabel {
                    if let h = value.as(Int.self) {
                        Text(Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date())?
                            .formatted(.dateTime.hour()) ?? "\(h)")
                            .font(.fb(.caption))
                            .foregroundStyle(.textSecondary)
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .chartPlotStyle { plot in
            plot.overlay(alignment: .bottom) { Rectangle().fill(.hairlineStrong).frame(height: FBStroke.hairline) }
        }
        .frame(height: 96)
        .accessibilityLabel(Text("Load by hour"))
        .accessibilityValue(Text(peakDescription))
    }

    private var peakDescription: String {
        guard let peak = hourly.indices.max(by: { hourly[$0] < hourly[$1] }), hourly[peak] > 0 else {
            return String(localized: "No load")
        }
        let label = Calendar.current.date(bySettingHour: peak, minute: 0, second: 0, of: Date())?.formatted(.dateTime.hour()) ?? "\(peak)"
        return String(localized: "Hardest hour: \(label)")
    }
}
