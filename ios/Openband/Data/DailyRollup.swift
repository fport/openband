import Foundation
import SwiftData

/// Recomputes the scores of the days a sync touched, and every later day (their baselines and
/// "yesterday's strain" depend on the earlier ones), bounded to the last 90 days (plan section 4:
/// "Etkilenen günlerin skorları yeniden hesaplanır (en fazla 90 gün)"). Writes one DailyScore per
/// band and day; days without any data lose their row.
@MainActor
enum DailyRollup {
    static let maxDays = 90

    /// - from: the earliest touched day; days before today - 89 are not recomputed.
    /// - now: the clock (today is the phone's current day; minutes after `now` are not counted).
    @discardableResult
    static func recompute(context: ModelContext, bandID: UUID, from: DayKey, now: Date = Date(),
                          profile: Profile = .load()) -> [DayScoreResult] {
        let today = DayKey.current(now)
        let start = max(from, today.adding(days: -(maxDays - 1)))
        guard start <= today else { return [] }
        let lo = start.index - 1, hi = today.index

        let minuteRows = (try? context.fetch(FetchDescriptor<MinuteDay>(
            predicate: #Predicate { $0.bandID == bandID && $0.dayIndex >= lo && $0.dayIndex <= hi }))) ?? []
        var minutes: [Int: MinuteSeries] = [:]
        for row in minuteRows where minutes[row.dayIndex] == nil { minutes[row.dayIndex] = row.series }

        let sleepRows = (try? context.fetch(FetchDescriptor<SleepRecord>(
            predicate: #Predicate { $0.bandID == bandID && $0.isPrimary && $0.dayIndex >= lo && $0.dayIndex <= hi },
            sortBy: [SortDescriptor(\.bedTime)]))) ?? []
        let rrRows = (try? context.fetch(FetchDescriptor<SleepRR>(
            predicate: #Predicate { $0.bandID == bandID && $0.dayIndex >= lo && $0.dayIndex <= hi }))) ?? []
        var rr: [String: [RRSegment]] = [:]
        for row in rrRows { rr[row.sourceFileID] = row.segments }
        var sleeps: [Int: [SleepInput]] = [:]
        for row in sleepRows {
            sleeps[row.dayIndex, default: []].append(row.draft(rr: rr[row.sourceFileID] ?? []).input)
        }

        let summaryRows = (try? context.fetch(FetchDescriptor<DaySummary>(
            predicate: #Predicate { $0.bandID == bandID && $0.dayIndex >= lo && $0.dayIndex <= hi }))) ?? []
        var restingHR: [Int: Int] = [:]
        for row in summaryRows { if let v = row.hrResting { restingHR[row.dayIndex] = v } }
        let summaryDays = Set(summaryRows.map(\.dayIndex))

        let historyLo = start.index - Baseline.lookbackDays, historyHi = start.index - 1
        let historyRows = (try? context.fetch(FetchDescriptor<DailyScore>(
            predicate: #Predicate { $0.bandID == bandID && $0.dayIndex >= historyLo && $0.dayIndex <= historyHi }))) ?? []
        let history = historyRows.map(\.historyPoint)

        var inputs: [DayInputs] = []
        for index in start.index ... today.index {
            let hasData = minutes[index] != nil || sleeps[index] != nil || summaryDays.contains(index)
            guard hasData else { continue }
            inputs.append(DayInputs(day: DayKey(index: index), minutes: minutes[index], previousMinutes: minutes[index - 1],
                                    sleeps: sleeps[index] ?? [], previousSleeps: sleeps[index - 1] ?? [],
                                    bandRestingHR: restingHR[index], now: index == today.index ? now : nil))
        }
        let results = ScoreEngine.scoreRange(inputs, history: history, profile: profile)

        let first = start.index
        let existing = (try? context.fetch(FetchDescriptor<DailyScore>(
            predicate: #Predicate { $0.bandID == bandID && $0.dayIndex >= first && $0.dayIndex <= hi }))) ?? []
        var rows: [Int: DailyScore] = [:]
        for row in existing {
            if rows[row.dayIndex] == nil { rows[row.dayIndex] = row } else { context.delete(row) }
        }
        let computed = Set(results.map(\.day.index))
        for result in results {
            if let row = rows[result.day.index] {
                row.update(from: result)
            } else {
                context.insert(DailyScore(bandID: bandID, result: result))
            }
        }
        for (index, row) in rows where !computed.contains(index) { context.delete(row) }
        try? context.save()
        return results
    }

    /// True when some stored score was computed by an older algorithm version.
    static func isStale(context: ModelContext) -> Bool {
        let current = ScoreEngine.algoVersion
        var descriptor = FetchDescriptor<DailyScore>(predicate: #Predicate { $0.algoVersion < current })
        descriptor.fetchLimit = 1
        return ((try? context.fetchCount(descriptor)) ?? 0) > 0
    }

    /// Today's steps: the larger of the band's files (minute sum or daily summary) and the latest
    /// live reading (plan: "Today's steps = max(file sum, live)").
    static func steps(context: ModelContext, bandID: UUID, day: DayKey, now: Date = Date()) -> Int? {
        let index = day.index
        let minute = (try? context.fetch(FetchDescriptor<MinuteDay>(
            predicate: #Predicate { $0.bandID == bandID && $0.dayIndex == index })))?.first?.series.stepTotal
        let summary = (try? context.fetch(FetchDescriptor<DaySummary>(
            predicate: #Predicate { $0.bandID == bandID && $0.dayIndex == index })))?.compactMap(\.steps).max()
        let start = day.start(offsetMinutes: TimeZone.current.secondsFromGMT(for: now) / 60)
        let end = start.addingTimeInterval(86_400)
        var descriptor = FetchDescriptor<Sample>(predicate: #Predicate { $0.bandID == bandID && $0.kind == "live" && $0.ts >= start && $0.ts < end },
                                                 sortBy: [SortDescriptor(\.ts, order: .reverse)])
        descriptor.fetchLimit = 1
        let live = (try? context.fetch(descriptor))?.first?.steps
        return [minute, summary, live].compactMap { $0 }.max()
    }
}
