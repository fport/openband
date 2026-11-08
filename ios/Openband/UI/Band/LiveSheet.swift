import Charts
import SwiftData
import SwiftUI

/// Live heart rate (medium sheet): the number, two minutes of line, min/avg/max, today's steps
/// and calories, and Stop. After the session it keeps the last readings and offers to start again.
struct LiveSheet: View {
    let band: Band

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var link: BandLink
    @EnvironmentObject private var router: AppRouter
    @Query private var samples: [Sample]

    init(band: Band) {
        self.band = band
        let id = band.id
        let start = Calendar.current.startOfDay(for: Date())
        _samples = Query(filter: #Predicate<Sample> { $0.bandID == id && $0.kind == "live" && $0.ts >= start },
                         sort: \Sample.ts)
    }

    private var live: Bool { BandPresentation.isLive(link, band) }
    private var starting: Bool { BandPresentation.isMine(link, band) && link.phase.isBusy && !live }

    /// The session's two minutes, or the two minutes before the last reading.
    private var window: ClosedRange<Date> {
        if live, let end = router.liveEndsAt { return end.addingTimeInterval(-BandLink.liveLimit)...end }
        // After a session: the readings of the last half hour before the latest one.
        let last = samples.last?.ts ?? Date()
        return last.addingTimeInterval(-30 * 60)...last
    }

    private var points: [NightPoint] {
        let w = window
        return samples.filter { $0.heartRate > 10 && w.contains($0.ts) }
            .map { NightPoint(date: $0.ts, value: Double($0.heartRate)) }
    }

    private var bpm: Int? {
        if live, let hr = link.stats?.heartRate, hr > 0 { return Int(hr) }
        return points.last.map { Int($0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: String(localized: "Live heart rate"))
            ScrollView {
                VStack(alignment: .leading, spacing: FBSpace.m) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(bpm.map { "\($0)" } ?? "–")
                            .textStyle(.figureXL)
                            .foregroundStyle(bpm == nil ? Color.textTertiary : Color.textPrimary)
                            .fbNumericTransition(Double(bpm ?? 0))
                        statusLine
                    }
                    .accessibilityElement(children: .combine)

                    Card {
                        if points.count > 1 {
                            Chart(points) { p in
                                LineMark(x: .value(String(localized: "Time"), p.date), y: .value(String(localized: "Heart rate"), p.value))
                                    .foregroundStyle(.heart)
                                    .lineStyle(StrokeStyle(lineWidth: FBStroke.chartLine))
                                    .interpolationMethod(.monotone)
                            }
                            .chartXScale(domain: window)
                            .chartXAxis(.hidden)
                            .chartYAxis {
                                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                                    AxisGridLine(stroke: StrokeStyle(lineWidth: FBStroke.hairline)).foregroundStyle(.hairline)
                                    AxisValueLabel {
                                        if let v = value.as(Double.self) {
                                            Text(FBFormat.number(v)).font(.fb(.caption)).foregroundStyle(.textSecondary)
                                        }
                                    }
                                }
                            }
                            .frame(height: 72)
                            .accessibilityLabel(live ? Text("Heart rate, last 2 minutes") : Text("Heart rate, last readings"))
                        } else {
                            Text("The line fills in as readings arrive.")
                                .textStyle(.subhead)
                                .foregroundStyle(.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
                        }
                    }

                    stats

                    VStack(alignment: .leading, spacing: FBSpace.xxs) {
                        Footnote(String(localized: "Keep the band's screen awake while live."))
                        Footnote(String(localized: "Stops after 2 minutes."))
                    }
                }
                .padding(.horizontal, FBSpace.gutter)
                .padding(.top, FBSpace.xs)
                .padding(.bottom, FBSpace.m)
            }
        }
        .fbPinnedPrimary(live ? String(localized: "Stop") : String(localized: "Start again"),
                         isEnabled: live || !link.phase.isBusy, secondary: live) {
            if live { model.stop() } else { model.start(band, .live) }
        }
        .fbSheet(.live)
    }

    private var statusLine: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let text: String = {
                let unit = String(localized: "bpm")
                if live, let end = router.liveEndsAt {
                    let left = max(0, Int(end.timeIntervalSince(timeline.date).rounded(.up)))
                    let clock = String(format: "%d:%02d", left / 60, left % 60)
                    return "\(unit) · " + String(localized: "Live · \(clock) left", comment: "Live HR status with time left")
                }
                if starting { return "\(unit) · " + link.phase.label }
                if let last = points.last {
                    return "\(unit) · " + String(localized: "Last reading \(FBFormat.time(last.date))")
                }
                return unit
            }()
            Text(text)
                .textStyle(.subhead)
                .foregroundStyle(.textSecondary)
        }
    }

    private var stats: some View {
        let values = points.map(\.value)
        let average = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        return VStack(alignment: .leading, spacing: FBSpace.s) {
            HStack(alignment: .top, spacing: 0) {
                stat(String(localized: "Min"), values.min())
                stat(String(localized: "Avg"), average)
                stat(String(localized: "Max"), values.max())
            }
            let stats = live ? link.stats : nil
            let steps = stats.map { Int($0.steps) } ?? samples.last?.steps
            let calories = stats.map { Int($0.calories) } ?? samples.last?.calories
            if let steps, let calories {
                Text("Steps \(FBFormat.number(steps)) · Calories \(FBFormat.number(calories))")
                    .textStyle(.subhead)
                    .foregroundStyle(.textSecondary)
            }
        }
    }

    private func stat(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .textStyle(.caption)
                .foregroundStyle(.textSecondary)
            Text(value.map { FBFormat.number($0) } ?? "–")
                .textStyle(.figureS)
                .foregroundStyle(.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
