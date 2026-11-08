import Combine
import Foundation
import SwiftData
import SwiftUI
import UIKit

/// Ties the band session to storage and integrations: every observation is stored as it
/// arrives; every activity file is stored, then parsed into the derived models; when a session
/// ends the touched days are scored again, webhooks get the session's samples and health records
/// and, if web access is on, unsent samples go to the hub.
@MainActor
final class AppModel: ObservableObject {
    let link = BandLink()
    let context: ModelContext
    let ingest: ActivityIngest

    /// The hub stores minute/sleep/score records since migration 0002 (deployed 2026-10-14).
    static let hubAcceptsHealthTypes = true

    @Published var hubStatus: String?
    @Published var hubBusy = false
    @Published var hubEnabled = Vault.hubToken != nil
    /// An invite opened from a QR code or the hub's /join page, waiting for the user to confirm.
    @Published var pendingInvite: Invite?
    /// Local midnight of the current day; changes at midnight and on clock/time-zone changes.
    @Published private(set) var today = Calendar.current.startOfDay(for: Date())
    /// The newest calibration report (plan section 4, phase 0).
    @Published private(set) var calibration: CalibrationReport?
    /// Parsing or scoring is running (reparse all, launch).
    @Published private(set) var ingestBusy = false

    /// Fires with the new day's midnight when the day changes while the app runs.
    let dayChanged = PassthroughSubject<Date, Never>()

    struct Invite: Identifiable, Equatable {
        let code: String
        let hub: URL
        var id: String { code + hub.absoluteString }
        var isDefaultHub: Bool { hub.host == HubClient.defaultURL.host }
    }

    private var sessionDrafts: [SampleDraft] = []
    /// What the ingests of the running session parsed, for its report and webhooks.
    private var sessionIngest = IngestSummary()
    /// Earliest day per band whose scores must be recomputed once no session is running.
    private var pendingRollup: [UUID: DayKey] = [:]
    private var ingestTask: Task<Void, Never>?
    private var ingestAgain = false
    /// Health records waiting for the hub (only while hubAcceptsHealthTypes).
    private var pendingHubRecords: [UUID: [[String: Any]]] = [:]
    private var dayObservers: [NSObjectProtocol] = []

    var hubURL: URL {
        get { UserDefaults.standard.string(forKey: "hubURL").flatMap(URL.init(string:)) ?? HubClient.defaultURL }
        set { UserDefaults.standard.set(newValue.absoluteString, forKey: "hubURL") }
    }

    var hub: HubClient { HubClient(baseURL: hubURL, token: Vault.hubToken) }

    /// The one model, for App Intents (Siri, Shortcuts).
    static weak var shared: AppModel?

    /// Demo mode (DemoMode.swift): an in-memory store with demo data. Band sessions can't start
    /// (the demo band has no key) and nothing reaches the hub or webhooks.
    let isDemo: Bool

    init(context: ModelContext, isDemo: Bool = false) {
        self.context = context
        self.isDemo = isDemo
        ingest = ActivityIngest(context: context)
        link.onSample = { [weak self] id, draft in self?.record(id, draft) }
        link.onFinish = { [weak self] id, outcome in self?.sessionEnded(id, outcome) }
        link.onRecord = { [weak self] id, record, peripheralID in self?.recordChanged(id, record, peripheralID) }
        link.onHistory = { [weak self] id, history in self?.ingestHistory(id, history) }
        link.onDeviceInfo = { [weak self] id, info in
            guard let self, let band = self.band(id) else { return }
            band.firmware = info.firmware.isEmpty ? band.firmware : info.firmware
            band.hardwareModel = info.model.isEmpty ? band.hardwareModel : info.model
            try? self.context.save()
        }
        calibration = Self.loadCalibration()
        mergeDuplicateBands()
        observeDayChanges()
        AppModel.shared = self
        if !isDemo { Task { await self.launchMaintenance() } }
    }

    // MARK: band sessions

    func target(for band: Band) -> BandTarget? {
        guard !isDemo else { return nil }
        var record = Vault.bandRecord(band.id) ?? HuaweiBandRecord.new(bandMAC: band.mac)
        if record.bandMAC == nil { record.bandMAC = band.mac }
        let from = band.lastSyncAt.map { $0.addingTimeInterval(-24 * 3600) } ?? Date().addingTimeInterval(-7 * 24 * 3600)
        return BandTarget(id: band.id, name: band.name, mac: band.mac, peripheralID: Self.peripheralID(band.id),
                          record: record, syncFrom: from)
    }

    /// The band's CoreBluetooth identifier on this phone; lets a session wait for the band
    /// without scanning.
    static func peripheralID(_ bandID: UUID) -> UUID? {
        UserDefaults.standard.string(forKey: "peripheral-\(bandID.uuidString)").flatMap(UUID.init(uuidString:))
    }

    static func setPeripheralID(_ id: UUID?, for bandID: UUID) {
        UserDefaults.standard.set(id?.uuidString, forKey: "peripheral-\(bandID.uuidString)")
    }

    func start(_ band: Band, _ purpose: BandLink.Purpose) {
        guard let target = target(for: band) else { return }
        sessionDrafts = []
        sessionIngest = IngestSummary()
        link.start(target, purpose: purpose)
    }

    func stop() { link.stop() }

    /// Uses the key the Mac already gave the band (`openband key`): no pairing, both keep working.
    @discardableResult
    func useSharedKey(_ text: String, for band: Band) -> Bool {
        guard var record = HuaweiBandRecord.fromSharedKey(text) else { return false }
        if record.bandMAC == nil { record.bandMAC = band.mac }
        Vault.setBandRecord(record, for: band.id)
        start(band, .check)
        return true
    }

    /// Hands the band a key of this phone's (again). Huawei Health loses the band after this.
    func pair(_ band: Band) {
        guard !isDemo else { return }
        var record = Vault.bandRecord(band.id) ?? HuaweiBandRecord.new(bandMAC: band.mac)
        record.bonded = false
        if record.bandMAC == nil { record.bandMAC = band.mac }
        Vault.setBandRecord(record, for: band.id)
        start(band, .pair)
    }

    private var notificationID: UInt32 = UInt32(Date().timeIntervalSince1970) % 100_000

    /// Shows a notification on the band.
    func notify(_ band: Band, title: String, body: String) {
        notificationID &+= 1
        start(band, .notify(title: title, body: body))
    }

    /// Starts or stops the band vibrating so it can be found.
    func findBand(_ band: Band, start vibrating: Bool) {
        // Huawei bands have no "find band" command; a notification vibrates them.
        guard vibrating else { return }
        start(band, .notify(title: "Openband", body: String(localized: "Here I am")))
    }

    /// Plan section 4 ("daily open"): when the app comes to the front, sync if the last sync is
    /// more than 15 minutes old, Bluetooth is on, no session is running and onboarding is done.
    func autoSyncIfNeeded(_ band: Band?, onboarded: Bool, now: Date = Date()) {
        guard onboarded, let band, link.bluetooth == .poweredOn, !link.phase.isBusy else { return }
        if let last = band.lastSyncAt, now.timeIntervalSince(last) < Self.autoSyncAfter { return }
        start(band, .sync)
    }

    static let autoSyncAfter: TimeInterval = 15 * 60

    /// For pull to refresh: starts a sync and returns when the session has ended.
    func syncAndWait(_ band: Band) async {
        guard !link.phase.isBusy else { return }
        start(band, .sync)
        try? await Task.sleep(for: .milliseconds(300))
        while link.phase.isBusy { try? await Task.sleep(for: .milliseconds(300)) }
    }

    private func record(_ id: UUID, _ draft: SampleDraft) {
        sessionDrafts.append(draft)
        context.insert(Sample(bandID: id, draft: draft))
        if draft.kind == "battery", let band = band(id) { band.lastBattery = draft.level }
        try? context.save()
    }

    /// `lastSyncAt` moves only on a complete session. Files that arrived are parsed whatever the
    /// outcome; webhooks get `sync.completed` or `sync.partial`, nothing on failure.
    private func sessionEnded(_ id: UUID, _ outcome: BandLink.Outcome) {
        let drafts = sessionDrafts
        sessionDrafts = []
        guard let band = band(id) else { return }
        if outcome == .complete {
            band.lastSyncAt = Date()
            try? context.save()
        }
        let device = Payload.Device(band)
        Task {
            await waitForIngest()
            let parsed = sessionIngest
            sessionIngest = IngestSummary()
            runPendingRollups()
            if !parsed.isEmpty {
                setCalibration(makeReport(parsed, bandID: id, outcome: outcome.label))
            }
            if case .failed = outcome { return }
            let records = healthRecords(bandID: id, parsed)
            guard !drafts.isEmpty || !records.isEmpty else { return }
            if Self.hubAcceptsHealthTypes, !records.isEmpty { pendingHubRecords[id, default: []] += records }
            await deliverWebhooks(event: outcome == .complete ? "sync.completed" : "sync.partial", device: device,
                                  drafts: drafts, records: records)
            await pushToHub()
        }
    }

    /// The band accepted our key, or showed up under an identifier on this phone.
    private func recordChanged(_ id: UUID, _ record: HuaweiBandRecord, _ peripheralID: UUID?) {
        if Vault.bandRecord(id) != record { Vault.setBandRecord(record, for: id) }
        if let peripheralID { Self.setPeripheralID(peripheralID, for: id) }
    }

    /// History from a sync: stored as minute days, day summaries and sleeps, then scored.
    private func ingestHistory(_ id: UUID, _ history: HuaweiHistory) {
        let result = HuaweiIngest.ingest(history, bandID: id, context: context)
        if let first = result.touchedDays.min() {
            pendingRollup[id] = min(pendingRollup[id] ?? first, first)
        }
        sessionIngest.touchedDays[id, default: []].formUnion(result.touchedDays)
        sessionIngest.minuteDays[id] = result.minuteDays
        sessionIngest.sleeps += result.sleeps
    }

    /// One band per MAC: folds bands added twice 
    /// into the oldest one, moving their samples, files, derived data and keys.
    func mergeDuplicateBands() {
        let bands = ((try? context.fetch(FetchDescriptor<Band>())) ?? []).sorted { $0.addedAt < $1.addedAt }
        var keeper: [String: Band] = [:]
        var changed = false
        for band in bands {
            guard let suffix = band.macSuffix else { continue }
            guard let first = keeper[suffix] else {
                keeper[suffix] = band
                continue
            }
            let from = band.id
            reassign(from: from, to: first.id)
            if Vault.bandRecord(first.id) == nil, let record = Vault.bandRecord(from) { Vault.setBandRecord(record, for: first.id) }
            Vault.removeBandRecord(from)
            if band.name.localizedCaseInsensitiveContains("pro"), !first.name.localizedCaseInsensitiveContains("pro") {
                first.name = band.name
                first.model = band.model
            }
            first.lastSyncAt = [first.lastSyncAt, band.lastSyncAt].compactMap { $0 }.max()
            if first.lastBattery == nil { first.lastBattery = band.lastBattery }
            if UserDefaults.standard.string(forKey: "selectedBand") == from.uuidString {
                UserDefaults.standard.set(first.id.uuidString, forKey: "selectedBand")
            }
            context.delete(band)
            changed = true
        }
        if changed { try? context.save() }
    }

    /// Moves every row of one band to another (bug fix 1). Raw files are deduplicated by file id
    /// (the newest copy stays); derived rows of both would overlap, so the keeper's derived rows
    /// and scores are dropped and its files marked for parsing again (the launch ingest rebuilds them).
    private func reassign(from: UUID, to: UUID) {
        for s in (try? context.fetch(FetchDescriptor<Sample>(predicate: #Predicate { $0.bandID == from }))) ?? [] { s.bandID = to }
        let moved = (try? context.fetch(FetchDescriptor<ActivityBlob>(predicate: #Predicate { $0.bandID == from }))) ?? []
        for b in moved { b.bandID = to }
        for r in (try? context.fetch(FetchDescriptor<MinuteDay>(predicate: #Predicate { $0.bandID == from }))) ?? [] { r.bandID = to }
        for r in (try? context.fetch(FetchDescriptor<DaySummary>(predicate: #Predicate { $0.bandID == from }))) ?? [] { r.bandID = to }
        for r in (try? context.fetch(FetchDescriptor<SleepRecord>(predicate: #Predicate { $0.bandID == from }))) ?? [] { r.bandID = to }
        for r in (try? context.fetch(FetchDescriptor<SleepRR>(predicate: #Predicate { $0.bandID == from }))) ?? [] { r.bandID = to }
        for r in (try? context.fetch(FetchDescriptor<ManualReading>(predicate: #Predicate { $0.bandID == from }))) ?? [] { r.bandID = to }
        for r in (try? context.fetch(FetchDescriptor<DailyScore>(predicate: #Predicate { $0.bandID == from }))) ?? [] { r.bandID = to }
        try? context.save()
        guard !moved.isEmpty else { return }

        let blobs = ((try? context.fetch(FetchDescriptor<ActivityBlob>(predicate: #Predicate { $0.bandID == to }))) ?? [])
            .sorted { $0.fetchedAt > $1.fetchedAt }
        var seen = Set<String>()
        for blob in blobs {
            if seen.insert(blob.fileID).inserted {
                blob.parserVersion = 0
                blob.parsedAt = nil
                blob.parseStatus = ParseStatus.pending.rawValue
            } else {
                context.delete(blob)
            }
        }
        ActivityIngest.deleteDerived(context: context, bandID: to, includingScores: true)
        pendingRollup[to] = DayKey.current().adding(days: -(DailyRollup.maxDays - 1))
        try? context.save()
    }

    // MARK: activity files

    private func blob(_ bandID: UUID, _ hex: String) -> ActivityBlob? {
        try? context.fetch(FetchDescriptor<ActivityBlob>(predicate: #Predicate { $0.bandID == bandID && $0.fileID == hex })).first
    }

    /// Parses pending files, one pass at a time; a request during a pass runs another after it.
    /// Scores wait until no session is running (runPendingRollups).
    func scheduleIngest() {
        if ingestTask != nil {
            ingestAgain = true
            return
        }
        ingestTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.ingestAgain = false
                let summary = await self.ingest.ingestPending()
                self.absorb(summary)
            } while self.ingestAgain
            self.ingestTask = nil
            self.runPendingRollups()
        }
    }

    private func absorb(_ summary: IngestSummary) {
        guard !summary.isEmpty else { return }
        sessionIngest.absorb(summary)
        for (band, day) in summary.earliestTouched {
            pendingRollup[band] = min(pendingRollup[band] ?? day, day)
        }
    }

    private func waitForIngest() async {
        while let task = ingestTask { await task.value }
    }

    /// Recomputes scores from the earliest touched day of each band; deferred while a session runs.
    func runPendingRollups() {
        guard !link.phase.isBusy, !pendingRollup.isEmpty else { return }
        let profile = Profile.load()
        let work = pendingRollup
        pendingRollup = [:]
        for (band, day) in work where self.band(band) != nil {
            DailyRollup.recompute(context: context, bandID: band, from: day, profile: profile)
        }
    }

    /// At launch: files below the current parser version, scores below the current algorithm.
    private func launchMaintenance() async {
        ingestBusy = true
        defer { ingestBusy = false }
        // Files 0.5.2 stored under another file's id (freeband#2): refiled, then all parsed again,
        // since minute days and sleeps merge rows from several files.
        if ingest.refileMisfiled() > 0 {
            absorb(await ingest.reparseAll())
            rescoreAll()
        }
        scheduleIngest()
        await waitForIngest()
        let quiet = !link.phase.isBusy
        let summary = sessionIngest
        if quiet { sessionIngest = IngestSummary() }
        if DailyRollup.isStale(context: context) { rescoreAll() }
        runPendingRollups()
        if quiet, !summary.isEmpty { setCalibration(makeReport(summary, bandID: nil, outcome: "launch reparse")) }
    }

    /// Every band, the last 90 days (algorithm or profile changed).
    func rescoreAll() {
        let from = DayKey.current().adding(days: -(DailyRollup.maxDays - 1))
        for band in (try? context.fetch(FetchDescriptor<Band>())) ?? [] { pendingRollup[band.id] = from }
        runPendingRollups()
    }

    /// Diagnostics: drops every derived row and score, parses every stored file again, rescores.
    func reparseAll() async {
        guard !ingestBusy else { return }
        ingestBusy = true
        defer { ingestBusy = false }
        await waitForIngest()
        // Holds the ingest slot so files stored meanwhile wait for the next pass.
        let job = Task { await self.ingest.reparseAll() }
        ingestTask = Task { _ = await job.value }
        let summary = await job.value
        ingestTask = nil
        rescoreAll()
        setCalibration(makeReport(summary, bandID: nil, outcome: "reparse all"))
        if ingestAgain {
            ingestAgain = false
            scheduleIngest()
        }
    }

    func band(_ id: UUID) -> Band? {
        try? context.fetch(FetchDescriptor<Band>(predicate: #Predicate { $0.id == id })).first
    }

    // MARK: day helpers for the UI

    /// Steps per hour of `day` (bug fix 2): from the minute file where there is one, otherwise
    /// the rise between live readings spread evenly over the time between them.
    func hourlySteps(bandID: UUID, day: Date = Date(), live: [(ts: Date, steps: Int)]) -> [Int] {
        let start = Calendar.current.startOfDay(for: day)
        let offset = TimeZone.current.secondsFromGMT(for: start) / 60
        let key = DayKey(date: start, offsetMinutes: offset)
        let index = key.index
        let row = try? context.fetch(FetchDescriptor<MinuteDay>(predicate: #Predicate { $0.bandID == bandID && $0.dayIndex == index })).first
        var minutes: [Int?]?
        if let series = row?.series {
            // The minute file is in the band's offset; move it onto the phone's day.
            let shift = Int(series.start.timeIntervalSince(start) / 60)
            if shift == 0 {
                minutes = series.steps
            } else {
                var moved = [Int?](repeating: nil, count: MinuteSeries.slots)
                for (i, v) in series.steps.enumerated() where i + shift >= 0 && i + shift < MinuteSeries.slots { moved[i + shift] = v }
                minutes = moved
            }
        }
        return HourlySteps.compute(minuteSteps: minutes, dayStart: start, readings: live)
    }

    /// The day's steps: max of the band's files and the latest live reading.
    func daySteps(bandID: UUID, day: Date = Date()) -> Int? {
        DailyRollup.steps(context: context, bandID: bandID, day: DayKey.current(day))
    }

    // MARK: day change (bug fix 3)

    private func observeDayChanges() {
        let names: [Notification.Name] = [
            .NSCalendarDayChanged, UIApplication.significantTimeChangeNotification,
            .NSSystemTimeZoneDidChange, UIApplication.willEnterForegroundNotification,
        ]
        for name in names {
            dayObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDay() }
            })
        }
    }

    /// Publishes a new `today` when the calendar day differs from the one shown.
    func refreshDay() {
        let start = Calendar.current.startOfDay(for: Date())
        guard start != today else { return }
        today = start
        dayChanged.send(start)
    }

    // MARK: keys

    /// Adds a band found while scanning, or returns the one already added with that MAC.
    @discardableResult
    func addBand(name rawName: String, mac: String, peripheralID: UUID?) -> Band? {
        guard !isDemo else { return nil }
        let name = rawName.replacingOccurrences(of: " (connected)", with: "")
        let clean = Band.normalizedMAC(mac)
        let bands = (try? context.fetch(FetchDescriptor<Band>())) ?? []
        let band = bands.first { $0.mac == clean } ?? {
            let new = Band(name: name, mac: clean)
            context.insert(new)
            return new
        }()
        band.name = name
        band.model = Band.modelCode(for: name)
        if Vault.bandRecord(band.id) == nil { Vault.setBandRecord(HuaweiBandRecord.new(bandMAC: clean), for: band.id) }
        if let peripheralID { Self.setPeripheralID(peripheralID, for: band.id) }
        try? context.save()
        return band
    }

    /// Removes the band with everything stored for it: samples, raw files, derived rows, scores.
    func remove(_ band: Band) {
        let id = band.id
        Vault.removeBandRecord(id)
        Self.setPeripheralID(nil, for: id)
        try? context.delete(model: Sample.self, where: #Predicate { $0.bandID == id })
        try? context.delete(model: ActivityBlob.self, where: #Predicate { $0.bandID == id })
        ActivityIngest.deleteDerived(context: context, bandID: id, includingScores: true)
        pendingRollup[id] = nil
        pendingHubRecords[id] = nil
        context.delete(band)
        try? context.save()
    }

    /// Deletes every observation, raw file, derived row and score; bands, keys and webhooks stay.
    func deleteAllData() {
        try? context.delete(model: Sample.self)
        try? context.delete(model: ActivityBlob.self)
        ActivityIngest.deleteDerived(context: context, bandID: nil, includingScores: true)
        pendingRollup = [:]
        pendingHubRecords = [:]
        try? context.save()
        setCalibration(nil)
    }

    // MARK: calibration

    private func makeReport(_ summary: IngestSummary, bandID: UUID?, outcome: String?) -> CalibrationReport {
        var minuteDays = summary.minuteDays.values.flatMap { $0 }
        // Summaries whose day was not rebuilt in this pass: compare with the stored minute day.
        let known = Set(minuteDays.map(\.day))
        let bandIDs = Set(summary.touchedDays.keys)
        for s in summary.summaries where !known.contains(s.day) {
            let index = s.day.index
            for band in bandIDs {
                if let row = try? context.fetch(FetchDescriptor<MinuteDay>(
                    predicate: #Predicate { $0.bandID == band && $0.dayIndex == index })).first {
                    minuteDays.append(row.draft)
                }
            }
        }
        return Calibration.build(files: summary.files, minuteFiles: summary.minuteFiles, minuteDays: minuteDays,
                                 summaries: summary.summaries, sleeps: summary.sleeps, fetchedAt: summary.fetchedAt,
                                 bandID: bandID?.uuidString, outcome: outcome, parserVersion: ActivityIngest.parserVersion,
                                 algoVersion: ScoreEngine.algoVersion)
    }

    private static var calibrationURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("calibration-latest.json")
    }

    private static func loadCalibration() -> CalibrationReport? {
        guard let url = calibrationURL, let data = try? Data(contentsOf: url) else { return nil }
        return CalibrationReport.decode(data)
    }

    private func setCalibration(_ report: CalibrationReport?) {
        calibration = report
        guard let url = Self.calibrationURL else { return }
        if let report {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? report.json().write(to: url, options: [.atomic, .completeFileProtection])
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The latest report as a JSON file to share.
    func exportCalibration() throws -> URL? {
        guard let calibration else { return nil }
        let stamp = Payload.iso.string(from: calibration.generatedAt).replacingOccurrences(of: ":", with: "")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("freeband-calibration-\(stamp).json")
        try calibration.json().write(to: url, options: .completeFileProtection)
        return url
    }

    // MARK: webhooks

    /// Minute, sleep and score records of what this session parsed (plan section 6).
    private func healthRecords(bandID: UUID, _ summary: IngestSummary) -> [[String: Any]] {
        var records: [[String: Any]] = []
        for draft in (summary.minuteDays[bandID] ?? []).sorted(by: { $0.day < $1.day }) {
            records += Payload.minuteRecords(draft.series)
        }
        let sleepIDs = Set(summary.sleeps.map(\.sourceFileID))
        if !sleepIDs.isEmpty {
            let rows = (try? context.fetch(FetchDescriptor<SleepRecord>(
                predicate: #Predicate { $0.bandID == bandID && $0.isPrimary }, sortBy: [SortDescriptor(\.bedTime)]))) ?? []
            records += rows.filter { sleepIDs.contains($0.sourceFileID) }.compactMap { Payload.sleepRecord($0.draft()) }
        }
        let days = summary.touchedDays[bandID] ?? []
        if let lo = days.min()?.index {
            let offset = TimeZone.current.secondsFromGMT() / 60
            let rows = (try? context.fetch(FetchDescriptor<DailyScore>(
                predicate: #Predicate { $0.bandID == bandID && $0.dayIndex >= lo }, sortBy: [SortDescriptor(\.dayIndex)]))) ?? []
            records += rows.map { Payload.scoreRecord($0, tzOffsetMinutes: offset) }
        }
        return records
    }

    private func deliverWebhooks(event: String, device: Payload.Device, drafts: [SampleDraft], records: [[String: Any]]) async {
        guard !isDemo else { return }
        let hooks = ((try? context.fetch(FetchDescriptor<Webhook>())) ?? []).filter(\.enabled)
        guard !hooks.isEmpty else { return }
        let bodies = Payload.bodies(event: event, device: device, samples: drafts, records: records)
        for hook in hooks {
            guard let url = URL(string: hook.url) else { continue }
            for body in bodies {
                hook.lastStatus = await WebhookSender.deliver(body, event: event, to: url, secret: hook.secret)
            }
            hook.lastAt = Date()
        }
        try? context.save()
    }

    func ping(_ hook: Webhook) async {
        guard let url = URL(string: hook.url) else { return }
        let bands = (try? context.fetch(FetchDescriptor<Band>())) ?? []
        let device = bands.first.map { Payload.Device($0) } ?? Payload.Device(id: UUID(), name: "Openband", model: "band10")
        let body = Payload.body(event: "ping", device: device, samples: [])
        hook.lastStatus = await WebhookSender.deliver(body, event: "ping", to: url, secret: hook.secret)
        hook.lastAt = Date()
        try? context.save()
    }

    // MARK: invites

    /// `freeband://join?invite=OB-XXXX-XXXX&hub=https://…`; only https hubs are accepted.
    func handle(_ url: URL) {
        guard url.scheme == "freeband", url.host == "join",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        let code = (items.first { $0.name == "invite" }?.value ?? "").trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty, code.count <= 64 else { return }
        let hub = items.first { $0.name == "hub" }?.value
            .flatMap(URL.init(string:))
            .flatMap { $0.scheme == "https" && $0.host != nil ? $0 : nil } ?? HubClient.defaultURL
        pendingInvite = Invite(code: code, hub: hub)
    }

    func accept(_ invite: Invite) async {
        hubURL = invite.hub
        await enableWebAccess(invite: invite.code)
    }

    // MARK: hub (web access)

    func enableWebAccess(invite: String) async {
        guard !isDemo else { hubStatus = String(localized: "Not available with demo data."); return }
        hubBusy = true
        defer { hubBusy = false }
        let name = ((try? context.fetch(FetchDescriptor<Band>())) ?? []).first?.name ?? "Openband"
        do {
            let account = try await HubClient(baseURL: hubURL).createAccount(deviceName: name, invite: invite)
            Vault.hubToken = account.token
            hubEnabled = true
            hubStatus = String(localized: "Web access is on.")
            await pushToHub()
        } catch {
            hubStatus = error.localizedDescription
        }
    }

    func disableWebAccess() async {
        guard !isDemo else { hubStatus = String(localized: "Not available with demo data."); return }
        hubBusy = true
        defer { hubBusy = false }
        do {
            try await hub.deleteAccount()
        } catch HubClient.Failure.status(401, _) {
            // already gone on the server
        } catch {
            hubStatus = error.localizedDescription
            return
        }
        Vault.hubToken = nil
        hubEnabled = false
        let all = (try? context.fetch(FetchDescriptor<Sample>())) ?? []
        all.forEach { $0.pushedToHub = false }
        try? context.save()
        hubStatus = String(localized: "Web access is off and your data on the server is deleted.")
    }

    /// Uses a key the user already has (rotated on the web panel, or from another phone): the
    /// key is kept only once the hub accepts it.
    func enterAPIKey(_ key: String) async {
        guard !isDemo else { hubStatus = String(localized: "Not available with demo data."); return }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        hubBusy = true
        defer { hubBusy = false }
        do {
            try await HubClient(baseURL: hubURL, token: key).verify()
            Vault.hubToken = key
            hubEnabled = true
            hubStatus = String(localized: "API key saved.")
            await pushToHub()
        } catch HubClient.Failure.status(401, _) {
            hubStatus = String(localized: "The server didn't recognise this key. Make sure you copied the latest key from the web panel.")
        } catch {
            hubStatus = error.localizedDescription
        }
    }

    func rotateToken() async {
        guard !isDemo else { hubStatus = String(localized: "Not available with demo data."); return }
        hubBusy = true
        defer { hubBusy = false }
        do {
            Vault.hubToken = try await hub.rotate()
            hubStatus = String(localized: "New API key created. The old one no longer works.")
        } catch {
            hubStatus = error.localizedDescription
        }
    }

    /// Sends every sample not yet on the hub, one request per band, up to 4000 at a time. Health
    /// records follow only once the hub accepts them (hubAcceptsHealthTypes).
    func pushToHub() async {
        guard !isDemo else { return }
        guard Vault.hubToken != nil else { return }
        let bands = (try? context.fetch(FetchDescriptor<Band>())) ?? []
        var sent = 0
        for band in bands {
            let id = band.id
            var descriptor = FetchDescriptor<Sample>(predicate: #Predicate { $0.bandID == id && !$0.pushedToHub },
                                                     sortBy: [SortDescriptor(\.ts)])
            descriptor.fetchLimit = 4000  // 5000 compact live samples exceed the hub's 512 KB body cap
            if let pending = try? context.fetch(descriptor), !pending.isEmpty {
                let body = Payload.body(event: "sync.completed", device: Payload.Device(band),
                                        samples: pending.map(SampleDraft.init(sample:)))
                do {
                    _ = try await hub.ingest(body)
                    pending.forEach { $0.pushedToHub = true }
                    sent += pending.count
                } catch {
                    hubStatus = error.localizedDescription
                    return
                }
            }
            if Self.hubAcceptsHealthTypes, let records = pendingHubRecords[id], !records.isEmpty {
                do {
                    for body in Payload.bodies(event: "sync.completed", device: Payload.Device(band), samples: [], records: records) {
                        _ = try await hub.ingest(body)
                    }
                    pendingHubRecords[id] = nil
                    sent += records.count
                } catch {
                    hubStatus = error.localizedDescription
                    return
                }
            }
        }
        try? context.save()
        if sent > 0 { hubStatus = String(localized: "Sent \(sent) records to the server.") }
    }
}
