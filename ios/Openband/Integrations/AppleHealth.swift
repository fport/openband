import Foundation
import HealthKit
import SwiftData

/// Apple Health, both ways, all on the phone:
///
/// * Out: what the band measured (steps, distance, active energy, heart rate, SpO2 and sleep) is
///   saved with a sync identifier per minute or span and a version that grows with every pass, so
///   syncing again replaces Health's copy instead of duplicating it or being dropped.
/// * In: steps the iPhone (or a watch) counted fill the minutes the band has nothing for, so a day
///   without the band on the wrist still has steps. Openband's own samples are left out.
///
/// Two permissions, two switches, and they are not symmetric: HealthKit can say whether saving is
/// allowed (`authorizationStatus(for:)`, which answers for sharing only) but never whether reading
/// is — a denied read looks exactly like an empty store. So writes are checked before every save
/// and reads stay an intent the user can verify in Health.
@MainActor
final class AppleHealth: ObservableObject {
    static let shared = AppleHealth()

    @Published var writeEnabled: Bool {
        didSet { UserDefaults.standard.set(writeEnabled, forKey: "health.write") }
    }
    @Published var readEnabled: Bool {
        didSet { UserDefaults.standard.set(readEnabled, forKey: "health.read") }
    }
    /// The last thing that happened, for Settings › Apple Health. Not private: AppleHealth+Workout
    /// reports through it too.
    @Published var status: String? {
        // A message set from anywhere but `report` is not something Health can fix.
        didSet { needsHealthApp = false }
    }
    /// True when `status` is something the user can only change in Health itself.
    @Published private(set) var needsHealthApp = false

    /// Made on first use, and only when HealthKit is there: Apple wants `isHealthDataAvailable()`
    /// before any other HealthKit call. One store for the app's lifetime, as Apple asks, so the
    /// queries it owns stay alive.
    private(set) lazy var store: HKHealthStore? = Self.isAvailable ? HKHealthStore() : nil

    private init() {
        writeEnabled = UserDefaults.standard.bool(forKey: "health.write")
        readEnabled = UserDefaults.standard.bool(forKey: "health.read")
    }

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Bounds a sample has to be inside to be worth sending, and the batch sizes.
    ///
    /// Out-of-range values are dropped, not clamped: HealthKit refuses an out-of-range quantity
    /// and refuses the whole `save` with it, and a junk protocol byte should stay visible in the
    /// diagnostics instead of becoming a plausible reading.
    private enum Limit {
        static let heartRate = 25 ... 250
        static let spo2 = 70 ... 100
        /// Health refuses samples of 24 h or more; a night longer than this is nonsense anyway.
        static let nightSeconds: TimeInterval = 20 * 3600
        /// Objects per `save`: one bad minute should cost its chunk, not the whole night.
        static let chunk = 2_000
        /// Days per statistics query, so a 90-day fill never builds 130k buckets at once.
        static let sliceDays = 7
    }

    private static let quantityTypes: [HKQuantityTypeIdentifier] = [
        .stepCount, .distanceWalkingRunning, .activeEnergyBurned, .heartRate, .oxygenSaturation,
    ]

    /// What `export` saves. Not private: AppleHealth+Workout needs it for its own request.
    var writeTypes: Set<HKSampleType> {
        var types = Set<HKSampleType>(Self.quantityTypes.map { HKQuantityType($0) })
        types.insert(HKCategoryType(.sleepAnalysis))
        return types
    }

    /// Step count alone: it is the one type Openband reads. Asking for heart rate and sleep too
    /// put them on the permission sheet for nothing.
    var readTypes: Set<HKObjectType> { [HKQuantityType(.stepCount)] }

    // MARK: permission

    /// Asks for the write types, then reports whether Health really allows saving. A request that
    /// does not throw proves nothing: it only means the sheet flow finished, and Apple returns it
    /// without showing a sheet at all once every type has been decided.
    func requestWriteAccess() async -> Bool {
        guard let store else {
            report(Self.unavailable)
            return false
        }
        let types = writeTypes
        let asked = await requestStatus(toShare: types, read: [])
        do {
            try await store.requestAuthorization(toShare: types, read: [])
        } catch {
            report(Self.message(for: error), needsHealthApp: Self.isPermissionProblem(error))
            return false
        }
        let refused = types.filter { !canWrite($0) }
        guard refused.count < types.count else {
            report(asked == .unnecessary
                ? String(localized: "Health already has an answer for Openband and won't ask again. Turn saving on in Health › Sources › Openband.")
                : String(localized: "Health didn't allow saving. You can change that in Health › Sources › Openband."),
                needsHealthApp: true)
            return false
        }
        report(refused.isEmpty ? nil
            : String(localized: "Health allows \(types.count - refused.count) of \(types.count) record types; the rest are in Health › Sources › Openband."),
            needsHealthApp: !refused.isEmpty)
        return true
    }

    /// Asks for step count. There is no matching check afterwards — HealthKit hides read
    /// permission on purpose — so this reports only that the flow finished, and says where the
    /// user can look if no steps turn up.
    func requestReadAccess() async -> Bool {
        guard let store else {
            report(Self.unavailable)
            return false
        }
        let asked = await requestStatus(toShare: [], read: readTypes)
        do {
            try await store.requestAuthorization(toShare: [], read: readTypes)
        } catch {
            report(Self.message(for: error), needsHealthApp: Self.isPermissionProblem(error))
            return false
        }
        report(String(localized: "If no iPhone steps turn up, Health isn't letting Openband read them: Health › Sources › Openband."),
               needsHealthApp: asked == .unnecessary)
        return true
    }

    /// Writing is the one permission HealthKit lets an app see, and the user can withdraw it in
    /// Health at any time without telling the app, so it is checked again whenever the screen
    /// appears and before every save.
    func canWrite(_ type: HKSampleType) -> Bool {
        store?.authorizationStatus(for: type) == .sharingAuthorized
    }

    /// Turns the write switch off again when Health has stopped allowing everything it covers.
    func refreshWriteAccess() {
        guard writeEnabled, store != nil, !writeTypes.contains(where: canWrite) else { return }
        writeEnabled = false
        report(String(localized: "Health no longer allows Openband to save. Turn saving on in Health › Sources › Openband."),
               needsHealthApp: true)
    }

    /// Whether Apple's sheet would appear at all: `.unnecessary` means every type already has an
    /// answer, so requesting again is a silent no-op and the user has to go to Health.
    private func requestStatus(toShare share: Set<HKSampleType>,
                               read: Set<HKObjectType>) async -> HKAuthorizationRequestStatus {
        guard let store else { return .unknown }
        return await withCheckedContinuation { continuation in
            store.getRequestStatusForAuthorization(toShare: share, read: read) { status, _ in
                continuation.resume(returning: status)
            }
        }
    }

    /// Sets `status` and whether Settings should offer to open Health with it.
    func report(_ text: String?, needsHealthApp: Bool = false) {
        status = text
        self.needsHealthApp = needsHealthApp
    }

    private static var unavailable: String {
        String(localized: "Apple Health isn't available on this device.")
    }

    private static func isPermissionProblem(_ error: Error) -> Bool {
        switch (error as? HKError)?.code {
        case .errorAuthorizationDenied, .errorRequiredAuthorizationDenied, .errorAuthorizationNotDetermined:
            return true
        default:
            return false
        }
    }

    /// HealthKit answers most failures with the same sentence, so each code gets copy that says
    /// what to do about it instead of its `localizedDescription`.
    static func message(for error: Error) -> String {
        guard let code = (error as? HKError)?.code else { return error.localizedDescription }
        switch code {
        case .errorHealthDataUnavailable:
            return unavailable
        case .errorHealthDataRestricted:
            return String(localized: "Health is turned off for this iPhone by a profile or by Screen Time.")
        case .errorAuthorizationDenied, .errorRequiredAuthorizationDenied:
            return String(localized: "Health didn't allow this. Turn Openband's categories on in Health › Sources › Openband.")
        case .errorAuthorizationNotDetermined:
            return String(localized: "Health hasn't been asked yet. Turn the switch on again to see Apple's permission sheet.")
        case .errorDatabaseInaccessible:
            return String(localized: "Health is locked. Unlock the iPhone and sync again.")
        case .errorInvalidArgument:
            return String(localized: "Health refused a record as out of range.")
        case .errorNotPermissibleForGuestUserMode:
            return String(localized: "Health isn't available in guest mode.")
        case .errorNoData:
            return String(localized: "Health has nothing for this stretch of time.")
        case .errorUserCanceled:
            return String(localized: "Cancelled.")
        default:
            return error.localizedDescription
        }
    }

    // MARK: out

    /// The band as Health sees it. `localIdentifier` is the band's own id, so this band's records
    /// can be picked out of Health later with `HKQuery.predicateForObjects(from:)` — the only
    /// reliable way to find or delete them again. The *source* stays Openband: there is no API to
    /// credit another vendor, and the band shows up under the sample's device detail instead.
    func device(for band: Band?, fallbackName: String = "Huawei Band") -> HKDevice {
        HKDevice(name: band?.displayName ?? fallbackName,
                 manufacturer: "Huawei",
                 model: band?.shortName ?? "Band",
                 // What the band itself reports as its model ("FRA-B19"), i.e. its hardware SKU.
                 hardwareVersion: band?.hardwareModel,
                 firmwareVersion: band?.firmware,
                 softwareVersion: band?.firmware,
                 localIdentifier: band?.id.uuidString,
                 udiDeviceIdentifier: nil)
    }

    /// Saves one sync's history. Pass `band` and `context` to get the band's real device details
    /// and the reconciled nights; without them it falls back to `bandName` and the live spans.
    func export(_ history: HuaweiHistory, bandName: String, band: Band? = nil,
                context: ModelContext? = nil, now: Date = Date()) async {
        guard writeEnabled, let store else { return }
        let allowed = Set(writeTypes.filter(canWrite).map(\.identifier))
        guard !allowed.isEmpty else {
            report(String(localized: "Health doesn't allow Openband to save. Turn saving on in Health › Sources › Openband."),
                   needsHealthApp: true)
            return
        }
        let device = device(for: band, fallbackName: bandName)
        let nights = exportNights(history, band: band, context: context)
        let minutes = Self.minutesToExport(history.minutes, exportedTo: band?.lastExportedTo, now: now)
        // Every revision needs a higher sync version than the copy Health holds, or the save is a
        // silent no-op (a corrected minute or a revised wake time would never land). The export's
        // own second is monotonic and needs nothing stored.
        let version = Int(now.timeIntervalSince1970)
        // A first sync is ~10k minutes across five types: built off the main actor, which is where
        // the UI lives.
        let samples = await Task.detached(priority: .utility) {
            Self.samples(minutes: minutes, nights: nights, device: device, allowed: allowed, version: version)
        }.value
        guard !samples.isEmpty else { return }

        // Chunked: HealthKit refuses a whole `save` over one bad sample, and a night is worth more
        // than a minute.
        var saved = 0
        var failure: Error?
        for start in stride(from: 0, to: samples.count, by: Limit.chunk) {
            let chunk = Array(samples[start ..< min(start + Limit.chunk, samples.count)])
            do {
                try await store.save(chunk)
                saved += chunk.count
            } catch {
                failure = error
            }
        }
        if let failure {
            let detail = Self.message(for: failure)
            report(saved > 0 ? String(localized: "Saved \(saved) of \(samples.count) records to Apple Health. \(detail)") : detail,
                   needsHealthApp: Self.isPermissionProblem(failure))
        } else {
            report(String(localized: "Saved \(saved) records to Apple Health."))
            advance(band, context: context, through: minutes)
        }
    }

    /// The minutes worth sending: everything past the band's export mark, and today over again.
    ///
    /// `export` used to send its whole window every sync — `lastSyncAt − 24 h`, a week on a first
    /// sync — which was a harmless no-op while every sample carried version 1. Against a version
    /// that grows with each pass it is a real rewrite of those minutes in Health instead, so the
    /// mark is what keeps a sync to what is new. Today is the exception, and also the bound: the
    /// band is still appending to today's files, so a minute sent an hour ago can still gain the
    /// values the band had not written down yet, and the re-export is never wider than one day.
    nonisolated private static func minutesToExport(_ minutes: [HuaweiMinuteSample], exportedTo: Date?,
                                                    now: Date, timeZone: TimeZone = .current) -> [HuaweiMinuteSample] {
        guard let exportedTo else { return minutes }
        let offset = timeZone.secondsFromGMT(for: now) / 60
        let midnight = DayKey(date: now, offsetMinutes: offset).start(offsetMinutes: offset)
        let cutoff = min(exportedTo, midnight)
        return minutes.filter { $0.timestamp >= cutoff }
    }

    /// Moves the band's export mark up to the last minute that went out.
    ///
    /// Only on a clean pass, and only as far as the data itself reached: a chunk that failed has to
    /// go again next time, and the band is rarely caught up to `now`. Nights are deliberately not
    /// part of the mark — `exportNights` reconciles them against the stored records, and a sleep
    /// details file parsed days later genuinely revises an old night, so nights stay worth
    /// re-sending. There are at most a handful of them per sync; the minutes are the thousands.
    private func advance(_ band: Band?, context: ModelContext?, through minutes: [HuaweiMinuteSample]) {
        guard let band, let reached = minutes.map({ $0.timestamp.addingTimeInterval(60) }).max(),
              band.lastExportedTo.map({ reached > $0 }) ?? true else { return }
        band.lastExportedTo = reached
        try? context?.save()
    }

    /// The nights to export. The stored records win where ingest has them: `isPrimary` picks the
    /// sleep details file over the stage file, and that file is the only place a real REM stage and
    /// the real bed time exist. The live spans cover a night whose files have not been parsed yet,
    /// and go through `HuaweiIngest` so the awake gaps between spans are reconstructed too.
    private func exportNights(_ history: HuaweiHistory, band: Band?, context: ModelContext?) -> [SleepDraft] {
        let live = HuaweiIngest.sleeps(history.sleep, timeZone: .current)
        guard let band, let context else { return live }
        let bandID = band.id
        let starts = live.map(\.bedTime) + history.minutes.map(\.timestamp)
        let ends = live.map(\.wakeTime) + history.minutes.map(\.timestamp)
        guard let from = starts.min(), let to = ends.max(), to > from else { return live }
        let stored = ((try? context.fetch(FetchDescriptor<SleepRecord>(predicate: #Predicate {
            $0.bandID == bandID && $0.isPrimary && $0.bedTime < to && $0.wakeTime > from
        }))) ?? []).map { $0.draft() }
        return stored + live.filter { night in !stored.contains { IngestMapper.sameSleep($0, night) } }
    }

    /// Every HealthKit object of one export. Pure and `nonisolated`, so it can run off the main
    /// actor over plain values.
    nonisolated private static func samples(minutes: [HuaweiMinuteSample], nights: [SleepDraft],
                                            device: HKDevice, allowed: Set<String>, version: Int) -> [HKSample] {
        var out: [HKSample] = []
        out.reserveCapacity(minutes.count * 3)
        for m in minutes {
            let start = m.timestamp
            let end = start.addingTimeInterval(60)
            // Cumulative types are totals over the minute, discrete ones are instants.
            func add(_ id: HKQuantityTypeIdentifier, _ value: Double, _ unit: HKUnit, instant: Bool = false) {
                guard allowed.contains(id.rawValue) else { return }
                out.append(HKQuantitySample(type: HKQuantityType(id),
                                            quantity: HKQuantity(unit: unit, doubleValue: value),
                                            start: start, end: instant ? start : end, device: device,
                                            metadata: meta("openband.\(id.rawValue).\(Int(start.timeIntervalSince1970))",
                                                           version)))
            }
            if let v = m.steps, v > 0 { add(.stepCount, Double(v), .count()) }
            if let v = m.distance, v > 0 { add(.distanceWalkingRunning, Double(v), .meter()) }
            if let v = m.kcal, v > 0 { add(.activeEnergyBurned, Double(v), .kilocalorie()) }
            if let v = m.heartRate, Limit.heartRate.contains(v) {
                add(.heartRate, Double(v), HKUnit.count().unitDivided(by: .minute()), instant: true)
            }
            if let v = m.spo2, Limit.spo2.contains(v) {
                // HealthKit's percent is 0...1, so 98 % is 0.98; 98 would be 9800 % and be refused.
                add(.oxygenSaturation, Double(v) / 100, .percent(), instant: true)
            }
        }
        if allowed.contains(HKCategoryTypeIdentifier.sleepAnalysis.rawValue) {
            for night in nights { out += sleepSamples(night, device: device, version: version) }
        }
        return out
    }

    /// One night the way Health models sleep: a single `.inBed` span with non-overlapping stage
    /// samples inside it. Light is Core and deep is Deep, a reconstructed gap between the band's
    /// spans is `.awake`, and a stage code we don't recognise is skipped rather than counted as
    /// asleep. `.asleepREM` is written only where a sleep details file actually reported REM — the
    /// Band 6 has no REM detection, and inventing one corrupts every app that reads REM.
    ///
    /// Stage identifiers are `s0…sN` off the night's bed time, so a revised night replaces its
    /// spans in place. A revision with fewer stages leaves the surplus tail behind in Health;
    /// clearing that needs `deleteObjects(of:predicate:)` over the night, which is not done here.
    nonisolated static func sleepSamples(_ night: SleepDraft, device: HKDevice,
                                         version: Int) -> [HKCategorySample] {
        let span = night.wakeTime.timeIntervalSince(night.bedTime)
        guard span > 0, span < Limit.nightSeconds else { return [] }
        let type = HKCategoryType(.sleepAnalysis)
        let id = "openband.sleep.\(Int(night.bedTime.timeIntervalSince1970))"
        var out = [HKCategorySample(type: type, value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                                    start: night.bedTime, end: night.wakeTime, device: device,
                                    metadata: meta("\(id).inbed", version))]
        var cursor = night.bedTime
        for (i, segment) in night.segments.sorted(by: { $0.start < $1.start }).enumerated() {
            let value: HKCategoryValueSleepAnalysis
            switch segment.stage {
            case .light: value = .asleepCore
            case .deep: value = .asleepDeep
            case .rem: value = .asleepREM
            case .awake: value = .awake
            case .notSleep, .unknown: continue
            }
            // Clamped into the in-bed span and behind the stage before it: Health wants the
            // detailed samples to overlap the in-bed sample but never each other.
            let start = max(segment.start, cursor)
            let end = min(segment.end, night.wakeTime)
            guard end > start else { continue }
            out.append(HKCategorySample(type: type, value: value.rawValue, start: start, end: end,
                                        device: device, metadata: meta("\(id).s\(i)", version)))
            cursor = end
        }
        return out
    }

    /// A sync identifier plus the version that lets a later pass replace the same datum, and the
    /// explicit "the band measured this, the user didn't type it" flag.
    nonisolated private static func meta(_ identifier: String, _ version: Int) -> [String: Any] {
        [HKMetadataKeySyncIdentifier: identifier,
         HKMetadataKeySyncVersion: version,
         HKMetadataKeyWasUserEntered: false]
    }

    // MARK: in

    /// iPhone steps since `from`, as (minute start, steps), Openband's own samples left out.
    ///
    /// The totals come from `HKStatisticsCollectionQuery`, which merges the sources the way Health
    /// itself does; adding up raw samples counts the iPhone and a paired Watch twice over. Our own
    /// samples are excluded by naming the other sources: a `NOT` around a source predicate is
    /// outside what HealthKit's SQL translation supports, so the filtering happens in Swift, on
    /// the `HKSource` list, before the query runs.
    func phoneSteps(from: Date, to: Date = Date()) async -> [(Date, Int)] {
        guard readEnabled, store != nil, to > from else { return [] }
        let others = await otherStepSources()
        guard !others.isEmpty else { return [] }
        // Minute buckets, in slices: a minute matches how the band's own series is stored, so the
        // phone's steps need no spreading, and a slice keeps a 90-day fill off one huge collection.
        let slice = TimeInterval(Limit.sliceDays) * 86_400
        var out: [(Date, Int)] = []
        var start = from
        while start < to {
            let end = min(start.addingTimeInterval(slice), to)
            out += await stepBuckets(from: start, to: end, sources: others)
            start = end
        }
        return out
    }

    /// Everything that writes step counts except Openband itself.
    private func otherStepSources() async -> Set<HKSource> {
        guard let store else { return [] }
        let ours = HKSource.default().bundleIdentifier
        return await withCheckedContinuation { continuation in
            let query = HKSourceQuery(sampleType: HKQuantityType(.stepCount), samplePredicate: nil) { _, sources, _ in
                continuation.resume(returning: Set((sources ?? []).filter { $0.bundleIdentifier != ours }))
            }
            store.execute(query)
        }
    }

    private func stepBuckets(from: Date, to: Date, sources: Set<HKSource>) async -> [(Date, Int)] {
        guard let store else { return [] }
        let anchor = Self.minute(from)
        // No `.strictStartDate`: a sample that straddles a slice boundary has to be in both
        // queries, and the query splits a cumulative sample over the buckets it covers, so each
        // slice takes only the minutes it enumerates.
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: from, end: to),
            HKQuery.predicateForObjects(from: sources),
        ])
        let query = HKStatisticsCollectionQuery(quantityType: HKQuantityType(.stepCount),
                                                quantitySamplePredicate: predicate,
                                                options: .cumulativeSum,
                                                anchorDate: anchor,
                                                intervalComponents: DateComponents(minute: 1))
        return await withCheckedContinuation { continuation in
            query.initialResultsHandler = { query, collection, error in
                store.stop(query)
                guard let collection else {
                    if let error {
                        Task { @MainActor in self.report(Self.message(for: error),
                                                         needsHealthApp: Self.isPermissionProblem(error)) }
                    }
                    continuation.resume(returning: [])
                    return
                }
                var out: [(Date, Int)] = []
                collection.enumerateStatistics(from: anchor, to: to) { statistics, _ in
                    guard let sum = statistics.sumQuantity() else { return }
                    let steps = Int(sum.doubleValue(for: .count()).rounded())
                    if steps > 0 { out.append((statistics.startDate, steps)) }
                }
                continuation.resume(returning: out)
            }
            store.execute(query)
        }
    }

    private static func minute(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
    }

    // MARK: anchors

    /// One anchored pass over Health's step samples: the stretch of time whose minutes have to be
    /// worked out again, and the anchor that marks it done.
    struct StepPass {
        let from: Date
        let to: Date
        /// Whether minutes inside the window may be emptied as well as filled. Only a pass that
        /// watched Health delete something clears; `changedSteps` says why.
        let clears: Bool
        let anchor: HKQueryAnchor?
    }

    /// What has changed in Health's step samples since the last pass, or nil when nothing has.
    ///
    /// `retention` bounds the work: it is as far back as the app keeps a day at all, and the first
    /// pass — the one with no anchor yet — recomputes the whole of it. `full` ignores the stored
    /// anchor, which is what Settings' "Fill gaps now" does, so a user who suspects the fill can
    /// always ask for the window again.
    ///
    /// Returning nil stores the new anchor on the way out: there is nothing left that could fail.
    func stepChanges(retention: Date, now: Date = Date(), full: Bool = false) async -> StepPass? {
        guard readEnabled, store != nil, now > retention else { return nil }
        let type = HKQuantityType(.stepCount)
        let stored = full ? nil : anchor(for: type)
        let delta = await changedSteps(since: stored, window: retention, now: now)
        // A first or forced pass has no change list worth narrowing by, so it redoes the window. A
        // pass that found deletions redoes it too, and is the only kind allowed to empty a minute.
        if stored == nil || delta.deletions {
            return StepPass(from: retention, to: now, clears: delta.deletions, anchor: delta.anchor)
        }
        let from = delta.first.map { max(retention, $0) }
        let to = delta.last.map { min(now, $0) }
        guard let from, let to, to > from else {
            if let anchor = delta.anchor { setAnchor(anchor, for: type) }
            return nil
        }
        return StepPass(from: from, to: to, clears: false, anchor: delta.anchor)
    }

    /// Stores the pass's anchor, once its days are written. Kept apart from `stepChanges` because
    /// one anchor covers every band: it may only move after the last band's minutes are in, or the
    /// second band would be told nothing had changed.
    func commit(_ pass: StepPass) {
        guard let anchor = pass.anchor else { return }
        setAnchor(anchor, for: HKQuantityType(.stepCount))
    }

    private struct StepDelta {
        var first: Date?
        var last: Date?
        var deletions = false
        var anchor: HKQueryAnchor?
    }

    /// `HKAnchoredObjectQuery` over step counts: what was added and whether anything was deleted
    /// since `anchor`, which is a cursor into Health's own sequence rather than a date, so each
    /// pass sees only what arrived after the last one.
    ///
    /// The predicate is the retained window, not the whole store: without it a first pass has to
    /// materialise every step sample this phone has ever recorded just to come away with an anchor.
    /// Openband's own samples are dropped by source — `export` writes step counts too, and a pass
    /// that recomputed the days it had itself just written would never settle.
    ///
    /// A deletion arrives as an `HKDeletedObject`: a uuid, and no date, value or source with it.
    /// There is no way to learn which minute it used to fill, so `stepChanges` answers one by
    /// recomputing the whole retained window from what Health reports now. A pass that saw nothing
    /// never clears, because HealthKit makes a refused read look exactly like an empty one.
    private func changedSteps(since anchor: HKQueryAnchor?, window: Date, now: Date) async -> StepDelta {
        guard let store else { return StepDelta() }
        let ours = HKSource.default().bundleIdentifier
        let predicate = HKQuery.predicateForSamples(withStart: window, end: nil)
        return await withCheckedContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: HKQuantityType(.stepCount), predicate: predicate,
                                              anchor: anchor,
                                              limit: HKObjectQueryNoLimit) { query, added, deleted, newAnchor, error in
                store.stop(query)
                if let error {
                    Task { @MainActor in self.report(Self.message(for: error),
                                                     needsHealthApp: Self.isPermissionProblem(error)) }
                    continuation.resume(returning: StepDelta())
                    return
                }
                var delta = StepDelta()
                delta.anchor = newAnchor
                delta.deletions = !(deleted ?? []).isEmpty
                for sample in added ?? [] where sample.sourceRevision.source.bundleIdentifier != ours {
                    delta.first = min(delta.first ?? sample.startDate, sample.startDate)
                    delta.last = max(delta.last ?? sample.endDate, sample.endDate)
                }
                continuation.resume(returning: delta)
            }
            store.execute(query)
        }
    }

    /// The anchor of the last anchored read of `type`, archived into UserDefaults.
    ///
    /// One key per type: an anchor is a position in Health's object sequence and says nothing about
    /// another type. `HKQueryAnchor` is `NSSecureCoding`, so it archives with secure coding on, and
    /// bytes that will not decode count as no anchor at all — one full pass, and no data lost.
    private func anchor(for type: HKSampleType) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: Self.anchorKey(type)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func setAnchor(_ anchor: HKQueryAnchor, for type: HKSampleType) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor,
                                                           requiringSecureCoding: true) else { return }
        UserDefaults.standard.set(data, forKey: Self.anchorKey(type))
    }

    private static func anchorKey(_ type: HKSampleType) -> String { "health.anchor.\(type.identifier)" }

    // MARK: filling

    /// Puts iPhone steps into the minutes the band left empty; returns the days it changed.
    ///
    /// They go into `MinuteDay.phoneSteps`, a column of their own, because `ActivityIngest`
    /// rebuilds `steps` from the parsed files alone: anything merged into that series is wiped the
    /// next time a file touching the day is parsed. `MinuteDay.series` merges the two at read
    /// time, with the band's own minutes always winning.
    ///
    /// The values come from the statistics query, never from the anchored pass's raw samples:
    /// Health merges the iPhone and a paired Watch, and adding raw samples up counts the steps
    /// they share twice over. `pass` only says which stretch of time to ask about.
    func fillGaps(bandID: UUID, context: ModelContext, pass: StepPass) async -> Set<DayKey> {
        let steps = await phoneSteps(from: pass.from, to: pass.to)
        guard !steps.isEmpty || pass.clears else { return [] }
        let tz = TimeZone.current
        // Every day the window can touch, and one either side: a day's stored offset is the band's
        // own and can put a minute on the day before or after the one the phone would guess.
        let lo = DayKey(date: pass.from, offsetMinutes: tz.secondsFromGMT(for: pass.from) / 60).index - 1
        let hi = DayKey(date: pass.to, offsetMinutes: tz.secondsFromGMT(for: pass.to) / 60).index + 1
        let rows = (try? context.fetch(FetchDescriptor<MinuteDay>(predicate: #Predicate {
            $0.bandID == bandID && $0.dayIndex >= lo && $0.dayIndex <= hi
        }))) ?? []
        var rowByIndex: [Int: MinuteDay] = [:]
        for row in rows where rowByIndex[row.dayIndex] == nil { rowByIndex[row.dayIndex] = row }

        // Day and slot come from the offset in force then: the band's own offset where it already
        // has a row for the day, the phone's offset for that day otherwise. Today's offset (what
        // this used to stamp) puts the steps an hour off after a clock change or a trip.
        var byDay: [DayKey: [(slot: Int, steps: Int)]] = [:]
        var offsets: [DayKey: Int] = [:]
        for (ts, value) in steps {
            let phoneOffset = tz.secondsFromGMT(for: ts) / 60
            let guess = DayKey(date: ts, offsetMinutes: phoneOffset)
            var placed = false
            for day in [guess, guess.adding(days: -1), guess.adding(days: 1)] {
                guard let offset = rowByIndex[day.index]?.tzOffsetMinutes,
                      let slot = day.minute(of: ts, offsetMinutes: offset) else { continue }
                byDay[day, default: []].append((slot, value))
                offsets[day] = offset
                placed = true
                break
            }
            if placed { continue }
            guard let slot = guess.minute(of: ts, offsetMinutes: phoneOffset) else { continue }
            byDay[guess, default: []].append((slot, value))
            offsets[guess] = phoneOffset
        }

        // A clearing pass visits every stored day the window covers, not only the days Health still
        // reports steps for: a day whose samples were all deleted has to end up empty too.
        var days = Set(byDay.keys)
        if pass.clears { days.formUnion(rows.map(\.dayKey)) }

        var changed = Set<DayKey>()
        for day in days {
            let row = rowByIndex[day.index]
            let offset = row?.tzOffsetMinutes ?? offsets[day] ?? 0
            let band = row?.fileSeries.steps ?? [Int?](repeating: nil, count: MinuteSeries.slots)
            var phone = row?.phoneStepSeries ?? [Int?](repeating: nil, count: MinuteSeries.slots)
            var touched = false
            if pass.clears {
                // Empty the minutes inside the window first, then put back what Health reports now.
                // A sample deleted in there has to stop filling its minute, and the deletion itself
                // never said which minute that was. Only minutes inside the window are touched, so
                // a narrow pass cannot reach a day's other steps.
                let midnight = day.start(offsetMinutes: offset)
                for slot in 0 ..< MinuteSeries.slots where phone[slot] != nil {
                    let at = midnight.addingTimeInterval(Double(slot) * 60)
                    guard at >= pass.from, at < pass.to else { continue }
                    phone[slot] = nil
                    touched = true
                }
            }
            for (slot, value) in byDay[day] ?? [] where band[slot] == nil && phone[slot] != value {
                phone[slot] = value
                touched = true
            }
            guard touched else { continue }
            if let row {
                row.setPhoneSteps(phone)
            } else {
                let empty = MinuteDayDraft(series: MinuteSeries(day: day, tzOffsetMinutes: offset), sourceFileIDs: [])
                let fresh = MinuteDay(bandID: bandID, draft: empty)
                fresh.setPhoneSteps(phone)
                context.insert(fresh)
            }
            changed.insert(day)
        }
        try? context.save()
        if !changed.isEmpty { report(String(localized: "Filled \(changed.count) day(s) with iPhone steps.")) }
        return changed
    }
}
