import Foundation
import SwiftData

/// Turns what a Huawei sync read (per-minute samples, light/deep sleep spans) into the stored
/// models the screens and scores use: MinuteDay, DaySummary and SleepRecord.
///
/// Idempotent: a minute day is merged slot by slot (new values win, empty slots keep the old
/// ones), a day summary is rebuilt from that merged day, and a sleep replaces any Huawei sleep
/// it overlaps.
@MainActor
enum HuaweiIngest {
    static let source = "huawei"
    /// Spans closer than this belong to the same sleep; the gap counts as awake.
    static let sleepGap: TimeInterval = 60 * 60
    /// A sleep shorter than this is a nap.
    static let napLimit: TimeInterval = 3 * 60 * 60

    struct Result {
        var touchedDays: Set<DayKey> = []
        var minuteDays: [MinuteDayDraft] = []
        var sleeps: [SleepDraft] = []
    }

    static func ingest(_ history: HuaweiHistory, bandID: UUID, context: ModelContext,
                       timeZone: TimeZone = .current) -> Result {
        var result = Result()
        let parts = minuteParts(history.minutes, timeZone: timeZone)
        for part in parts {
            let merged = merge(part, bandID: bandID, context: context)
            result.minuteDays.append(merged)
            result.touchedDays.insert(merged.day)
            replaceSummary(for: merged, bandID: bandID, context: context)
        }
        for sleep in sleeps(history.sleep, timeZone: timeZone) {
            replaceSleep(sleep, bandID: bandID, context: context)
            result.sleeps.append(sleep)
            result.touchedDays.insert(sleep.day)
        }
        try? context.save()
        return result
    }

    // MARK: minutes

    static func minuteParts(_ samples: [HuaweiMinuteSample], timeZone: TimeZone) -> [MinuteDayDraft] {
        var byDay: [DayKey: MinuteSeries] = [:]
        for s in samples {
            let offset = timeZone.secondsFromGMT(for: s.timestamp) / 60
            let day = DayKey(date: s.timestamp, offsetMinutes: offset)
            let local = Int(s.timestamp.timeIntervalSince1970) + offset * 60
            let slot = ((local % 86_400) + 86_400) % 86_400 / 60
            var series = byDay[day] ?? MinuteSeries(day: day, tzOffsetMinutes: offset)
            if let v = s.steps { series.steps[slot] = v }
            if let v = s.heartRate, v > 0 { series.heartRate[slot] = v }
            if let v = s.spo2, v > 0 { series.spo2[slot] = v }
            if let v = s.kcal { series.kcal[slot] = v }
            if let v = s.distance { series.distance[slot] = v }
            byDay[day] = series
        }
        return byDay.keys.sorted().compactMap { day in
            byDay[day].map { MinuteDayDraft(series: $0, sourceFileIDs: [source]) }
        }
    }

    private static func merge(_ part: MinuteDayDraft, bandID: UUID, context: ModelContext) -> MinuteDayDraft {
        let index = part.day.index
        let rows = (try? context.fetch(FetchDescriptor<MinuteDay>(predicate: #Predicate {
            $0.bandID == bandID && $0.dayIndex == index
        }))) ?? []
        guard let row = rows.first else {
            context.insert(MinuteDay(bandID: bandID, draft: part))
            return part
        }
        for extra in rows.dropFirst() { context.delete(extra) }
        var series = row.series
        let new = part.series
        for i in 0 ..< MinuteSeries.slots {
            if let v = new.steps[i] { series.steps[i] = v }
            if let v = new.heartRate[i] { series.heartRate[i] = v }
            if let v = new.spo2[i] { series.spo2[i] = v }
            if let v = new.kcal[i] { series.kcal[i] = v }
            if let v = new.distance[i] { series.distance[i] = v }
        }
        let merged = MinuteDayDraft(series: series, sourceFileIDs: [source])
        row.update(from: merged)
        return merged
    }

    private static func replaceSummary(for day: MinuteDayDraft, bandID: UUID, context: ModelContext) {
        let index = day.day.index
        let id = "\(source)-\(day.day.string)"
        try? context.delete(model: DaySummary.self, where: #Predicate { $0.bandID == bandID && $0.dayIndex == index && $0.sourceFileID == id })
        let s = day.series
        let hr = s.heartRate.compactMap { $0 }
        let spo2 = s.spo2.compactMap { $0 }
        let steps = s.steps.compactMap { $0 }
        let kcal = s.kcal.compactMap { $0 }
        let draft = DaySummaryDraft(
            day: day.day, tzOffsetMinutes: s.tzOffsetMinutes, sourceFileID: id, fileVersion: 0,
            steps: steps.isEmpty ? nil : steps.reduce(0, +),
            activeCalories: kcal.isEmpty ? nil : kcal.reduce(0, +), calories: nil,
            hrResting: nil, hrMin: hr.min(), hrMax: hr.max(),
            hrAvg: hr.isEmpty ? nil : hr.reduce(0, +) / hr.count,
            stressAvg: nil, stressMin: nil, stressMax: nil, standingMask: nil,
            spo2Avg: spo2.isEmpty ? nil : spo2.reduce(0, +) / spo2.count, spo2Min: spo2.min(), spo2Max: spo2.max(),
            trainingLoadDay: nil, trainingLoadWeek: nil, trainingLoadLevel: nil,
            vitalityCurrent: nil, vitalityLight: nil, vitalityModerate: nil, vitalityHigh: nil, recoveryHours: nil)
        context.insert(DaySummary(bandID: bandID, draft: draft))
    }

    // MARK: sleep

    static func sleeps(_ spans: [HuaweiSleepSpan], timeZone: TimeZone) -> [SleepDraft] {
        let sorted = spans.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var groups: [[HuaweiSleepSpan]] = []
        for span in sorted {
            if let last = groups.last?.last, span.start.timeIntervalSince(last.end) <= sleepGap {
                groups[groups.count - 1].append(span)
            } else {
                groups.append([span])
            }
        }
        return groups.compactMap { group in draft(group, timeZone: timeZone) }
    }

    private static func draft(_ group: [HuaweiSleepSpan], timeZone: TimeZone) -> SleepDraft? {
        guard let first = group.first, let wake = group.map(\.end).max() else { return nil }
        var segments: [StageSegment] = []
        var deep = 0, light = 0, awake = 0, wakings = 0
        var cursor = first.start
        for span in group {
            let gap = Int(span.start.timeIntervalSince(cursor) / 60)
            if gap > 0 {
                segments.append(StageSegment(start: cursor, minutes: gap, stage: .awake))
                awake += gap
                wakings += 1
            }
            let stage: StageKind
            switch span.kind {
            case .deep: stage = .deep; deep += span.minutes
            case .light: stage = .light; light += span.minutes
            case .unknown: stage = .unknown
            }
            segments.append(StageSegment(start: span.start, minutes: span.minutes, stage: stage))
            cursor = max(cursor, span.end)
        }
        let offset = timeZone.secondsFromGMT(for: wake) / 60
        return SleepDraft(sourceFileID: "\(source)-sleep-\(Int(first.start.timeIntervalSince1970))", kind: .stages,
                          fileVersion: 0, day: DayKey(date: wake, offsetMinutes: offset), tzOffsetMinutes: offset,
                          bedTime: first.start, wakeTime: wake, deepMinutes: deep, lightMinutes: light,
                          remMinutes: nil, awakeMinutes: awake, segments: segments, hrStart: nil,
                          hrIntervalSeconds: 60, hrValues: [], spo2Start: nil, spo2IntervalSeconds: 60,
                          spo2Values: [], wakeCount: wakings, sleepQuality: nil,
                          isNap: wake.timeIntervalSince(first.start) < napLimit, rr: [])
    }

    private static func replaceSleep(_ sleep: SleepDraft, bandID: UUID, context: ModelContext) {
        let bed = sleep.bedTime
        let wake = sleep.wakeTime
        let existing = (try? context.fetch(FetchDescriptor<SleepRecord>(predicate: #Predicate {
            $0.bandID == bandID && $0.bedTime < wake && $0.wakeTime > bed
        }))) ?? []
        for record in existing where record.sourceFileID.hasPrefix(source) { context.delete(record) }
        context.insert(SleepRecord(bandID: bandID, draft: sleep))
    }
}
