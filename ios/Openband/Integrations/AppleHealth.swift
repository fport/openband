import Foundation
import HealthKit
import SwiftData

/// Apple Health, both ways, all on the phone:
///
/// * Out: what the band measured (steps, distance, active energy, heart rate, SpO2, light and deep
///   sleep) is saved with a sync identifier per minute or span, so syncing again replaces instead
///   of duplicating.
/// * In: steps the iPhone (or a watch) counted fill the minutes the band has nothing for, so a
///   day without the band on the wrist still has steps. Openband's own samples are left out.
@MainActor
final class AppleHealth: ObservableObject {
    static let shared = AppleHealth()

    @Published var writeEnabled: Bool {
        didSet { UserDefaults.standard.set(writeEnabled, forKey: "health.write") }
    }
    @Published var readEnabled: Bool {
        didSet { UserDefaults.standard.set(readEnabled, forKey: "health.read") }
    }
    @Published private(set) var status: String?

    private let store = HKHealthStore()

    private init() {
        writeEnabled = UserDefaults.standard.bool(forKey: "health.write")
        readEnabled = UserDefaults.standard.bool(forKey: "health.read")
    }

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private static let quantityTypes: [HKQuantityTypeIdentifier] = [
        .stepCount, .distanceWalkingRunning, .activeEnergyBurned, .heartRate, .oxygenSaturation,
    ]

    private var writeTypes: Set<HKSampleType> {
        var types = Set<HKSampleType>(Self.quantityTypes.map { HKQuantityType($0) })
        types.insert(HKCategoryType(.sleepAnalysis))
        return types
    }

    private var readTypes: Set<HKObjectType> {
        [HKQuantityType(.stepCount), HKQuantityType(.heartRate), HKCategoryType(.sleepAnalysis)]
    }

    /// Shows Apple's permission sheet (once per type; later calls return at once).
    func requestAccess() async -> Bool {
        guard Self.isAvailable else {
            status = String(localized: "Apple Health isn't available on this device.")
            return false
        }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            status = nil
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    // MARK: out

    /// Saves one sync's history. Each sample carries a sync identifier, so Health keeps one copy.
    func export(_ history: HuaweiHistory, bandName: String) async {
        guard writeEnabled, Self.isAvailable else { return }
        let device = HKDevice(name: bandName, manufacturer: "Huawei", model: "Band 6", hardwareVersion: nil,
                              firmwareVersion: nil, softwareVersion: nil, localIdentifier: nil, udiDeviceIdentifier: nil)
        var samples: [HKSample] = []
        for m in history.minutes {
            let start = m.timestamp
            let end = start.addingTimeInterval(60)
            func add(_ id: HKQuantityTypeIdentifier, _ value: Double, _ unit: HKUnit, at: Date? = nil) {
                let key = "openband.\(id.rawValue).\(Int(start.timeIntervalSince1970))"
                samples.append(HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: value),
                                                start: at ?? start, end: at ?? end, device: device,
                                                metadata: [HKMetadataKeySyncIdentifier: key, HKMetadataKeySyncVersion: 1]))
            }
            if let v = m.steps, v > 0 { add(.stepCount, Double(v), .count()) }
            if let v = m.distance, v > 0 { add(.distanceWalkingRunning, Double(v), .meter()) }
            if let v = m.kcal, v > 0 { add(.activeEnergyBurned, Double(v), .kilocalorie()) }
            if let v = m.heartRate, v > 0 { add(.heartRate, Double(v), HKUnit.count().unitDivided(by: .minute()), at: start) }
            if let v = m.spo2, v > 0 { add(.oxygenSaturation, Double(v) / 100, .percent(), at: start) }
        }
        for span in history.sleep where span.end > span.start {
            let value: HKCategoryValueSleepAnalysis
            switch span.kind {
            case .deep: value = .asleepDeep
            case .light: value = .asleepCore
            case .unknown: value = .asleepUnspecified
            }
            let key = "openband.sleep.\(Int(span.start.timeIntervalSince1970))"
            samples.append(HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: value.rawValue,
                                            start: span.start, end: span.end, device: device,
                                            metadata: [HKMetadataKeySyncIdentifier: key, HKMetadataKeySyncVersion: 1]))
        }
        guard !samples.isEmpty else { return }
        do {
            try await store.save(samples)
            status = String(localized: "Saved \(samples.count) records to Apple Health.")
        } catch {
            status = error.localizedDescription
        }
    }

    // MARK: in

    /// iPhone steps since `from`, as (minute start, steps), Openband's own samples left out.
    /// A sample longer than a minute is spread evenly over its minutes.
    func phoneSteps(from: Date, to: Date = Date()) async -> [(Date, Int)] {
        guard readEnabled, Self.isAvailable else { return [] }
        let ours = HKQuery.predicateForObjects(from: HKSource.default())
        let window = HKQuery.predicateForSamples(withStart: from, end: to)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [window, NSCompoundPredicate(notPredicateWithSubpredicate: ours)])
        let descriptor = HKSampleQueryDescriptor(predicates: [.quantitySample(type: HKQuantityType(.stepCount), predicate: predicate)],
                                                 sortDescriptors: [SortDescriptor(\.startDate)])
        guard let samples = try? await descriptor.result(for: store) else { return [] }
        var perMinute: [Date: Double] = [:]
        for s in samples {
            let steps = s.quantity.doubleValue(for: .count())
            let first = Self.minute(s.startDate)
            let minutes = max(1, Int(ceil(s.endDate.timeIntervalSince(first) / 60)))
            for i in 0 ..< minutes {
                perMinute[first.addingTimeInterval(Double(i) * 60), default: 0] += steps / Double(minutes)
            }
        }
        return perMinute.keys.sorted().map { ($0, Int(perMinute[$0]!.rounded())) }.filter { $0.1 > 0 }
    }

    private static func minute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    /// Puts iPhone steps into the minutes the band left empty; returns the days it changed.
    func fillGaps(bandID: UUID, context: ModelContext, from: Date) async -> Set<DayKey> {
        let steps = await phoneSteps(from: from)
        guard !steps.isEmpty else { return [] }
        let tz = TimeZone.current
        var byDay: [DayKey: [(Int, Int)]] = [:]
        for (ts, value) in steps {
            let offset = tz.secondsFromGMT(for: ts) / 60
            let day = DayKey(date: ts, offsetMinutes: offset)
            let local = Int(ts.timeIntervalSince1970) + offset * 60
            byDay[day, default: []].append((((local % 86_400) + 86_400) % 86_400 / 60, value))
        }
        var changed = Set<DayKey>()
        for (day, slots) in byDay {
            let index = day.index
            let row = (try? context.fetch(FetchDescriptor<MinuteDay>(predicate: #Predicate {
                $0.bandID == bandID && $0.dayIndex == index
            })))?.first
            var series = row?.series ?? MinuteSeries(day: day, tzOffsetMinutes: tz.secondsFromGMT() / 60)
            var touched = false
            for (slot, value) in slots where series.steps[slot] == nil {
                series.steps[slot] = value
                touched = true
            }
            guard touched else { continue }
            let draft = MinuteDayDraft(series: series, sourceFileIDs: (row?.sourceFileIDs ?? []) + ["apple-health"])
            if let row { row.update(from: draft) } else { context.insert(MinuteDay(bandID: bandID, draft: draft)) }
            changed.insert(day)
        }
        try? context.save()
        if !changed.isEmpty { status = String(localized: "Filled \(changed.count) day(s) with iPhone steps.") }
        return changed
    }
}
