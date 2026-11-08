import SwiftData
import SwiftUI

/// Trends: one range for every card; each card opens the full chart with scrubbing and a day list.
struct TrendsView: View {
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var model: AppModel
    @AppStorage("trendRange") private var rangeValue = TrendRange.month.rawValue

    static let metrics: [TrendMetric] = [.recovery, .sleepHours, .strain, .restingHeartRate, .steps, .bloodOxygen, .stress]

    private var range: Binding<TrendRange> {
        Binding(get: { TrendRange(rawValue: rangeValue) ?? .month }, set: { rangeValue = $0.rawValue })
    }

    var body: some View {
        NavigationStack(path: $router.trendsPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: FBSpace.m) {
                    SegmentedPicker(String(localized: "Range"), selection: range, options: TrendRange.allCases) { $0.title }
                    SelectedBand { band in
                        if let band {
                            BandHealthReader(band: band) { history in
                                let today = DayKey.current(model.today)
                                ForEach(Self.metrics) { metric in
                                    NavigationLink(value: Route.trend(metric, day: today.index)) {
                                        Card {
                                            TrendChart(metric: metric, points: history.points(metric, ending: today),
                                                       range: range, showsRangePicker: false, style: .compact)
                                                .padding(.trailing, FBSpace.xs)
                                        }
                                        .overlay(alignment: .topTrailing) {
                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(.textTertiary)
                                                .padding(.top, FBSpace.m)
                                                .padding(.trailing, FBSpace.s - 2)
                                                .accessibilityHidden(true)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        } else {
                            EmptyState(systemImage: "chart.xyaxis.line", title: String(localized: "No band yet"),
                                       message: String(localized: "Add your band to see how your days compare."))
                        }
                    }
                }
                .padding(.horizontal, FBSpace.gutter)
                .padding(.bottom, FBSpace.xl)
            }
            .fbScreen()
            .navigationTitle(String(localized: "Trends"))
            .navigationBarTitleDisplayMode(.large)
            .routeDestinations()
        }
    }
}

/// The full chart for one metric with scrubbing, then every day of the range, newest first.
struct TrendDetailView: View {
    let metric: TrendMetric
    let day: DayKey
    let band: Band
    let history: HealthHistory

    @EnvironmentObject private var model: AppModel
    @AppStorage("trendRange") private var rangeValue = TrendRange.month.rawValue
    @Query private var liveSamples: [Sample]

    init(metric: TrendMetric, day: DayKey, band: Band, history: HealthHistory) {
        self.metric = metric
        self.day = day
        self.band = band
        self.history = history
        let id = band.id
        let start = Calendar.current.startOfDay(for: Date())
        _liveSamples = Query(filter: #Predicate<Sample> { $0.bandID == id && $0.kind == "live" && $0.ts >= start },
                             sort: \Sample.ts)
    }

    private var range: Binding<TrendRange> {
        Binding(get: { TrendRange(rawValue: rangeValue) ?? .month }, set: { rangeValue = $0.rawValue })
    }

    /// Today's steps include the latest live reading, as on Today.
    private var overrides: [DayKey: Double] {
        guard metric == .steps else { return [:] }
        let today = DayKey.current(model.today)
        let steps = [model.daySteps(bandID: band.id), liveSamples.last?.steps].compactMap { $0 }.max()
        return steps.map { [today: Double($0)] } ?? [:]
    }

    var body: some View {
        let points = history.points(metric, ending: day, override: overrides)
        let days = points.suffix(range.wrappedValue.rawValue).reversed().filter { $0.value != nil }
        ScrollView {
            VStack(alignment: .leading, spacing: FBSpace.l) {
                Card { TrendChart(metric: metric, points: points, range: range) }
                VStack(alignment: .leading, spacing: FBSpace.xs) {
                    SectionHeader(title: String(localized: "Days"))
                    if days.isEmpty {
                        Footnote(String(localized: "No data for these days."))
                    } else {
                        ListCard {
                            ForEach(Array(days.enumerated()), id: \.element.id) { i, point in
                                ListRow(title: FBFormat.shortDay(point.date.addingTimeInterval(12 * 3600)),
                                        value: point.value.map { metric.display($0) }, accessory: .none,
                                        showsDivider: i < days.count - 1)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, FBSpace.gutter)
            .padding(.bottom, FBSpace.xl)
        }
        .fbScreen()
        .navigationTitle(metric.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension TrendMetric {
    /// A value with its unit, for lists: "7h 12m", "56 bpm", "96%", "6,412".
    func display(_ value: Double) -> String {
        switch self {
        case .sleepHours: FBFormat.duration(minutes: value * 60)
        case .restingHeartRate: FBFormat.bpm(value)
        case .bloodOxygen: FBFormat.percent(value / 100)
        case .activeMinutes: String(localized: "\(Int(value.rounded())) min")
        default: format(value)
        }
    }
}
