import CoreBluetooth
import Foundation

/// What a session needs to find and unlock one band.
struct BandTarget {
    let id: UUID
    let name: String
    let mac: String?
    /// The band's CoreBluetooth identifier on this phone, once known.
    let peripheralID: UUID?
    let record: HuaweiBandRecord
    /// History is read from here on.
    let syncFrom: Date
}

/// One BLE session with a Huawei band at a time: find it (a known peripheral, one iOS holds, or
/// an advert), open FE86 (write FE01, notify FE02), run the handshake from Band/Huawei, then read
/// what the purpose asks for and let go. Protocol details: docs/PROTOCOL.md.
final class BandLink: NSObject, ObservableObject {
    enum Purpose: Equatable {
        /// Battery, firmware, today's totals; sets the clock.
        case check
        /// `check` plus per-minute history and sleep since the target's `syncFrom`.
        case sync
        /// Today's totals every few seconds until stopped.
        case live
        /// Writes a new key to the band (the only purpose allowed to), then `check`.
        case pair
        /// Shows a notification on the band.
        case notify(title: String, body: String)
    }

    enum Outcome: Equatable {
        case complete
        case partial(String)
        case failed(LinkError)

        var isSuccess: Bool { self == .complete }

        var label: String {
            switch self {
            case .complete: return "complete"
            case .partial(let reason): return "partial: \(reason)"
            case .failed(let error): return "failed: \(error.code)"
            }
        }
    }

    enum LinkError: Error, Equatable {
        case bluetoothOff
        case unauthorized
        case bluetoothUnsupported
        case bluetoothNotReady
        /// The band does not know our key: pair it (again).
        case needsPairing
        /// Normal-mode pairing needs the band's MAC from Settings › About on the band.
        case needsBandMAC
        /// The band asked for full HiChain, which Openband does not speak yet.
        case unsupportedPairing
        case notFound
        case timeout
        case disconnected
        case connectFailed
        case channelUnavailable
        case channelRefused
        case notRead

        var code: String {
            switch self {
            case .bluetoothOff: return "bluetooth_off"
            case .unauthorized: return "unauthorized"
            case .bluetoothUnsupported: return "bluetooth_unsupported"
            case .bluetoothNotReady: return "bluetooth_not_ready"
            case .needsPairing: return "needs_pairing"
            case .needsBandMAC: return "needs_band_mac"
            case .unsupportedPairing: return "unsupported_pairing"
            case .notFound: return "not_found"
            case .timeout: return "timeout"
            case .disconnected: return "disconnected"
            case .connectFailed: return "connect_failed"
            case .channelUnavailable: return "channel_unavailable"
            case .channelRefused: return "channel_refused"
            case .notRead: return "not_read"
            }
        }

        var message: String {
            switch self {
            case .bluetoothOff: return BandLink.message(for: .poweredOff)
            case .unauthorized: return BandLink.message(for: .unauthorized)
            case .bluetoothUnsupported: return BandLink.message(for: .unsupported)
            case .bluetoothNotReady: return BandLink.message(for: .unknown)
            case .needsPairing: return String(localized: "The band doesn't know this phone's key. Pair it again.")
            case .needsBandMAC: return String(localized: "Pairing needs the band's MAC address: on the band, Settings › About.")
            case .unsupportedPairing: return String(localized: "This band asks for a pairing method Openband doesn't support yet.")
            case .notFound: return String(localized: "Band not found. Wake its screen, keep it close and turn Bluetooth off on any other phone it's paired with.")
            case .timeout: return String(localized: "The band didn't answer. Wake its screen and try again.")
            case .disconnected: return String(localized: "The connection dropped. Bring the band closer and try again.")
            case .connectFailed: return String(localized: "Couldn't connect to the band. Turn Bluetooth off and on, then try again.")
            case .channelUnavailable: return String(localized: "This band doesn't offer the Bluetooth channel Openband uses.")
            case .channelRefused: return String(localized: "The band didn't open its data channel. Try again.")
            case .notRead: return String(localized: "Couldn't read the band.")
            }
        }

        static func bluetooth(_ state: CBManagerState) -> LinkError {
            switch state {
            case .poweredOff: return .bluetoothOff
            case .unauthorized: return .unauthorized
            case .unsupported: return .bluetoothUnsupported
            default: return .bluetoothNotReady
            }
        }

        static func from(_ error: Error) -> LinkError {
            guard let error = error as? HuaweiError else { return .notRead }
            switch error {
            case .timeout: return .timeout
            case .disconnected: return .disconnected
            case .needsBond, .badChallenge, .noSessionKey: return .needsPairing
            case .needsBandMAC: return .needsBandMAC
            case .hiChainUnsupported: return .unsupportedPairing
            case .refused, .unexpected: return .notRead
            }
        }
    }

    enum Phase: Equatable {
        case idle, searching, connecting, authenticating, reading, live, done
        case partial(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .searching, .connecting, .authenticating, .reading, .live: return true
            default: return false
            }
        }

        var label: String {
            switch self {
            case .idle: return ""
            case .searching: return String(localized: "Searching…")
            case .connecting: return String(localized: "Connecting…")
            case .authenticating: return String(localized: "Verifying…")
            case .reading: return String(localized: "Reading…")
            case .live: return String(localized: "Live")
            case .done: return String(localized: "Synced")
            case .partial(let reason): return reason
            case .failed(let message): return message
            }
        }
    }

    /// A Huawei band seen while scanning (onboarding).
    struct Discovered: Identifiable, Equatable {
        let id: UUID
        var name: String
        var rssi: Int
        /// Named like a Huawei band or advertising FE86.
        var isHuawei = true
    }

    static let fe86 = CBUUID(string: "FE86")
    static let writeUUID = CBUUID(string: "FE01")
    static let notifyUUID = CBUUID(string: "FE02")
    static let liveLimit: TimeInterval = 120
    static let sessionLimit: TimeInterval = 40

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var bandID: UUID?
    @Published private(set) var stats: BandInfo.LiveStats?
    @Published private(set) var battery: Int?
    @Published private(set) var log: [String] = []
    /// Bands that iOS holds a connection to right now.
    @Published private(set) var nearby: Set<UUID> = []
    @Published private(set) var bluetooth: CBManagerState = .unknown
    @Published private(set) var lastOutcome: Outcome?
    @Published private(set) var deviceState: BandInfo.DeviceState?
    /// Records read so far during a sync.
    @Published private(set) var fileProgress: (done: Int, total: Int)?
    @Published private(set) var discovered: [Discovered] = []
    /// Every device seen while scanning, Huawei or not: a scan that sees nothing at all points to
    /// Bluetooth permission, not to the band.
    @Published private(set) var seenCount = 0
    private var seenIDs = Set<UUID>()

    /// Every observation (live totals, battery) as it arrives.
    var onSample: ((UUID, SampleDraft) -> Void)?
    /// The session ended, with how it went.
    var onFinish: ((UUID, Outcome) -> Void)?
    var onDeviceInfo: ((UUID, BandInfo.DeviceInfo) -> Void)?
    /// The pairing record changed (bonded now) or the peripheral got an identifier on this phone.
    var onRecord: ((UUID, HuaweiBandRecord, UUID?) -> Void)?
    /// History read during a sync.
    var onHistory: ((UUID, HuaweiHistory) -> Void)?
    /// "Find phone" tapped on the band while a session is open.
    var onFindPhone: ((UUID) -> Void)?

    private var central: CBCentralManager!
    private var target: BandTarget?
    private var purpose = Purpose.check
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var channel: HuaweiChannel?
    private var worker: Task<Void, Never>?
    private var active = false
    private var authed = false
    private var finishing = false
    private var scanningForList = false
    private var run = 0
    private var pendingStart: (() -> Void)?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: control

    func start(_ target: BandTarget, purpose: Purpose) {
        guard !phase.isBusy else { return }
        stopScan()
        run += 1
        let thisRun = run
        self.target = target
        self.purpose = purpose
        bandID = target.id
        stats = nil
        battery = nil
        log = []
        peripheral = nil
        writeChar = nil
        notifyChar = nil
        channel = nil
        worker?.cancel()
        worker = nil
        authed = false
        finishing = false
        deviceState = nil
        fileProgress = nil
        active = true
        note("start: \(target.name), \(purpose)")

        let limit = purpose == .live ? Self.liveLimit + Self.sessionLimit : (purpose == .sync ? 180 : Self.sessionLimit)
        after(limit, thisRun) { [weak self] in
            guard let self, self.active else { return }
            self.fail(.timeout)
        }

        switch central.state {
        case .poweredOn:
            locate(thisRun)
        case .unknown, .resetting:
            phase = .searching
            pendingStart = { [weak self] in self?.locate(thisRun) }
        default:
            fail(.bluetooth(central.state))
        }
    }

    /// Ends live or sync early; what was read so far is kept.
    func stop() {
        guard active else { return }
        note("stopped by user")
        worker?.cancel()
        finish(.complete)
    }

    /// Cheap check, no session: which of these bands iOS is connected to right now.
    func refreshNearby(_ bands: [(id: UUID, suffix: String?)]) {
        guard central.state == .poweredOn else {
            nearby = []
            return
        }
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.fe86]).compactMap { $0.name?.uppercased() }
        nearby = Set(bands.compactMap { band in
            guard let suffix = band.suffix?.uppercased(), connected.contains(where: { $0.hasSuffix(suffix) }) else { return nil }
            return band.id
        })
    }

    // MARK: scanning (onboarding)

    func startScan() {
        guard !phase.isBusy else { return }
        discovered = []
        seenIDs = []
        seenCount = 0
        scanningForList = true
        if central.state == .poweredOn {
            // A band iOS already holds (Huawei Health, or the system after a pairing) does not
            // advertise; list it too.
            // Generic Access/Attribute and Device Information are on every band, so this finds one
            // iOS keeps connected for another app (Huawei Health) even before FE86 is known here.
            let services = [Self.fe86, CBUUID(string: "1800"), CBUUID(string: "1801"), CBUUID(string: "180A")]
            for held in central.retrieveConnectedPeripherals(withServices: [Self.fe86]) {
                discovered.append(Discovered(id: held.identifier, name: (held.name ?? "Huawei band") + " (connected)", rssi: 0))
            }
            for held in central.retrieveConnectedPeripherals(withServices: services)
                where Self.isHuawei(name: held.name, serviceUUIDs: []) && !discovered.contains(where: { $0.id == held.identifier }) {
                discovered.append(Discovered(id: held.identifier, name: (held.name ?? "Huawei band") + " (connected)", rssi: 0))
            }
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else {
            pendingStart = { [weak self] in self?.startScan() }
        }
    }

    func stopScan() {
        guard scanningForList else { return }
        scanningForList = false
        if central.isScanning { central.stopScan() }
    }

    static func isHuawei(name: String?, serviceUUIDs: [CBUUID]) -> Bool {
        if serviceUUIDs.contains(fe86) { return true }
        guard let name = name?.lowercased() else { return false }
        return name.hasPrefix("huawei band") || name.hasPrefix("honor band") || name.hasPrefix("huawei watch")
    }

    // MARK: finding the band

    private func locate(_ thisRun: Int) {
        guard run == thisRun, active, let target else { return }
        phase = .searching
        if let id = target.peripheralID, let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            // A pending connection: completes as soon as the band shows up, even when it only
            // advertises briefly after its screen wakes.
            note("known peripheral, waiting for it")
            connect(known)
            return
        }
        let services = [Self.fe86, CBUUID(string: "1800"), CBUUID(string: "1801"), CBUUID(string: "180A")]
        if let held = central.retrieveConnectedPeripherals(withServices: services).first(where: { nameMatches($0.name) }) {
            note("connected in iOS: \(held.name ?? "?")")
            connect(held)
            return
        }
        note("scanning for adverts")
        central.scanForPeripherals(withServices: nil, options: nil)
        after(20, thisRun) { [weak self] in
            guard let self, self.phase == .searching else { return }
            self.central.stopScan()
            self.fail(.notFound)
        }
    }

    /// The band advertises "HUAWEI Band 6-EF1": the last three hex digits of its MAC.
    private func nameMatches(_ name: String?) -> Bool {
        guard let name, let target else { return false }
        let hex = (target.mac ?? "").uppercased().filter(\.isHexDigit)
        if hex.count >= 3 { return name.uppercased().hasSuffix(String(hex.suffix(3))) }
        return name == target.name
    }

    private func connect(_ p: CBPeripheral) {
        if central.isScanning { central.stopScan() }
        peripheral = p
        p.delegate = self
        phase = .connecting
        central.connect(p, options: nil)
    }

    // MARK: session

    private func startSession(on p: CBPeripheral) {
        guard let writeChar, let target else { return }
        let maxWrite = max(20, p.maximumWriteValueLength(for: .withResponse))
        // CoreBluetooth calls back on the main queue (see init), so this is the main actor.
        let channel = MainActor.assumeIsolated {
            let channel = HuaweiChannel(session: HuaweiSession(), maxWrite: maxWrite, write: { [weak p] data in
                p?.writeValue(data, for: writeChar, type: .withResponse)
            })
            channel.onLog = { [weak self] line in self?.note(line) }
            channel.onUnsolicited = { [weak self] message, tlv in self?.unsolicited(message, tlv) }
            return channel
        }
        self.channel = channel
        phase = .authenticating
        let purpose = self.purpose
        let thisRun = run
        worker = Task { @MainActor [weak self] in
            await self?.runSession(channel, target: target, purpose: purpose, thisRun: thisRun)
        }
    }

    @MainActor
    private func runSession(_ channel: HuaweiChannel, target: BandTarget, purpose: Purpose, thisRun: Int) async {
        do {
            var record = target.record
            let report = try await huaweiAuthenticate(channel, record: record, allowBond: purpose == .pair)
            guard run == thisRun else { return }
            authed = true
            note("authenticated (\(report.params.path))")
            if report.bondedNow || !record.bonded {
                record.bonded = true
            }
            onRecord?(target.id, record, peripheral?.identifier)
            phase = .reading

            if case let .notify(title, body) = purpose {
                let id = Int(Date().timeIntervalSince1970 * 10) & 0xFFFF
                _ = try? await channel.request(HuaweiControls.notification(id: id, title: title, text: body), timeout: 4)
                finish(.complete)
                return
            }

            let details = try await huaweiAfterAuth(channel)
            battery = details.battery
            onSample?(target.id, .battery(details.battery))
            onDeviceInfo?(target.id, BandInfo.DeviceInfo(serial: details.product.serialNumber ?? "",
                                                         firmware: details.product.softwareVersion,
                                                         model: details.product.model))
            try? await huaweiSetTime(channel)
            try await readTotals(channel, target)

            switch purpose {
            case .sync:
                let history = try await huaweiFetchHistory(channel, start: target.syncFrom, end: Date()) { [weak self] kind, count in
                    self?.note("\(kind): \(count)")
                    self?.fileProgress = (count, count)
                }
                onHistory?(target.id, history)
                finish(history.errors.isEmpty ? .complete
                       : .partial(String(localized: "Some records couldn't be read. They come with the next sync.")))
            case .live:
                phase = .live
                let until = Date().addingTimeInterval(Self.liveLimit)
                while !Task.isCancelled, Date() < until, run == thisRun {
                    try await Task.sleep(for: .seconds(5))
                    try await readTotals(channel, target)
                }
                finish(.complete)
            default:
                finish(.complete)
            }
        } catch is CancellationError {
            return
        } catch {
            guard run == thisRun else { return }
            note("error: \(error)")
            fail(LinkError.from(error))
        }
    }

    @MainActor
    private func readTotals(_ channel: HuaweiChannel, _ target: BandTarget) async throws {
        let totals = try await huaweiFitnessTotals(channel)
        let live = BandInfo.LiveStats(steps: UInt64(max(totals.steps, 0)), calories: UInt64(max(totals.calories, 0)),
                                      heartRate: 0, standingHours: 0)
        stats = live
        onSample?(target.id, .live(live))
    }

    private func unsolicited(_ message: HuaweiMessage, _ tlv: HuaweiTLV) {
        if message.service == HuaweiControls.findPhone, message.command == HuaweiControls.findPhoneEvent,
           HuaweiControls.findPhoneStarted(tlv), let id = target?.id, let channel {
            Task { @MainActor in try? await channel.send(HuaweiControls.stopFindPhone()) }
            onFindPhone?(id)
        }
    }

    private func finish(_ outcome: Outcome) {
        guard active, !finishing else { return }
        finishing = true
        release()
        switch outcome {
        case .complete: phase = .done
        case .partial(let reason): phase = .partial(reason)
        case .failed(let error): phase = .failed(error.message)
        }
        note("result: \(outcome.label)")
        lastOutcome = outcome
        if let id = target?.id { onFinish?(id, outcome) }
    }

    private func fail(_ error: LinkError) {
        guard active else { return }
        note("error: \(error.code)")
        if authed, purpose == .sync || purpose == .live {
            finish(.partial(error.message))
            return
        }
        worker?.cancel()
        finish(.failed(error))
    }

    private func release() {
        active = false
        pendingStart = nil
        if let channel { MainActor.assumeIsolated { channel.fail(HuaweiError.disconnected) } }
        channel = nil
        if central.isScanning { central.stopScan() }
        if let p = peripheral {
            if let notifyChar, notifyChar.isNotifying { p.setNotifyValue(false, for: notifyChar) }
            central.cancelPeripheralConnection(p)
        }
        note("released")
    }

    // MARK: helpers

    private func after(_ seconds: TimeInterval, _ thisRun: Int, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.run == thisRun else { return }
            work()
        }
    }

    private func note(_ text: String) {
        log.append("\(Date().formatted(date: .omitted, time: .standard))  \(text)")
    }

    static func message(for state: CBManagerState) -> String {
        switch state {
        case .poweredOff: return String(localized: "Bluetooth is off. Turn it on in Control Centre.")
        case .unauthorized: return String(localized: "Openband can't use Bluetooth. Allow it in Settings › Openband.")
        case .unsupported: return String(localized: "This device doesn't support Bluetooth LE.")
        default: return String(localized: "Bluetooth isn't ready. Try again in a moment.")
        }
    }
}

extension BandLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetooth = central.state
        if central.state == .poweredOn, let start = pendingStart {
            pendingStart = nil
            start()
        } else if active, central.state != .poweredOn, central.state != .unknown, central.state != .resetting {
            fail(.bluetooth(central.state))
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        if scanningForList {
            if seenIDs.insert(peripheral.identifier).inserted { seenCount = seenIDs.count }
            let huawei = Self.isHuawei(name: name, serviceUUIDs: services)
            let rssi = RSSI.intValue
            // Everything close by is listed too: a band that hides its name still shows up on top.
            guard huawei || (name != nil && rssi > -75) || rssi > -60 else { return }
            if let i = discovered.firstIndex(where: { $0.id == peripheral.identifier }) {
                if rssi != 127 { discovered[i].rssi = rssi }
                if let name { discovered[i].name = name }
                discovered[i].isHuawei = discovered[i].isHuawei || huawei
            } else {
                discovered.append(Discovered(id: peripheral.identifier, name: name ?? "Unnamed device",
                                             rssi: rssi == 127 ? -100 : rssi, isHuawei: huawei))
            }
            return
        }
        guard phase == .searching, target != nil else { return }
        guard peripheral.identifier == target?.peripheralID || nameMatches(name) else { return }
        note("found advertising (\(RSSI) dBm)")
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard active, peripheral == self.peripheral else { return }
        note("connected")
        peripheral.discoverServices([Self.fe86])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard active, peripheral == self.peripheral else { return }
        fail(.connectFailed)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard active, peripheral == self.peripheral else { return }
        if let channel { MainActor.assumeIsolated { channel.fail(HuaweiError.disconnected) } }
        fail(.disconnected)
    }
}

extension BandLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard active else { return }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.fe86 }) else {
            fail(.channelUnavailable)
            return
        }
        peripheral.discoverCharacteristics([Self.writeUUID, Self.notifyUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard active else { return }
        writeChar = service.characteristics?.first { $0.uuid == Self.writeUUID }
        notifyChar = service.characteristics?.first { $0.uuid == Self.notifyUUID }
        guard let notifyChar, writeChar != nil else {
            fail(.channelUnavailable)
            return
        }
        peripheral.setNotifyValue(true, for: notifyChar)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard active, characteristic.uuid == Self.notifyUUID else { return }
        if error != nil {
            fail(.channelRefused)
        } else if characteristic.isNotifying, channel == nil {
            startSession(on: peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.notifyUUID, let value = characteristic.value, let channel else { return }
        MainActor.assumeIsolated { channel.receive(value) }
    }
}
