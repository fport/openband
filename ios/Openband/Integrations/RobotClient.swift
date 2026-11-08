import Foundation
import Network

/// The phone side of so101-band's phone server (so101-band run --phone): finds the Mac over Bonjour
/// (`_so101band._tcp`), sends what so101-remote's ESP32 screen sends and reads back the arm's state.
/// Everything stays on the local network.
@MainActor
final class RobotClient: ObservableObject {
    struct State: Decodable, Equatable {
        var live: Bool?
        var state: String?
        var speed: Int?
        var joints: [String: Double]?
        var volts: Double?
        var gesture: String?
        var message: String?
        var sequence: [String]?
        var poses: [String]?
        var routines: [String]?
        var joint_names: [String]?
    }

    enum Link: Equatable {
        case searching
        case found(String)
        case needsCode
        case connected
        case failed(String)
    }

    static let service = "_so101band._tcp"
    static let jointLabels = ["shoulder_pan": "Pan", "shoulder_lift": "Lift", "elbow_flex": "Elbow",
                              "wrist_flex": "Wrist", "wrist_roll": "Roll", "gripper": "Gripper"]

    @Published private(set) var link: Link = .searching
    @Published private(set) var state: State?
    @Published private(set) var macName: String?
    @Published var code: String = UserDefaults.standard.string(forKey: "robot.code") ?? "" {
        didSet { UserDefaults.standard.set(code, forKey: "robot.code") }
    }
    /// Typed by hand when Bonjour finds nothing: "192.168.1.20:8765".
    @Published var manualAddress: String = UserDefaults.standard.string(forKey: "robot.address") ?? "" {
        didSet { UserDefaults.standard.set(manualAddress, forKey: "robot.address") }
    }

    private var browser: NWBrowser?
    private var resolver: NWConnection?
    private var base: URL?
    private var poller: Task<Void, Never>?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        return URLSession(configuration: config)
    }()

    // MARK: finding the Mac

    func start() {
        guard poller == nil else { return }
        if let url = Self.url(manualAddress) {
            use(url, name: manualAddress)
        } else {
            browse()
        }
    }

    func stop() {
        poller?.cancel()
        poller = nil
        browser?.cancel()
        browser = nil
        resolver?.cancel()
        resolver = nil
    }

    func retry() {
        stop()
        link = .searching
        state = nil
        start()
    }

    static func url(_ address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let withPort = trimmed.contains(":") ? trimmed : trimmed + ":8765"
        return URL(string: "http://\(withPort)")
    }

    private func browse() {
        link = .searching
        let browser = NWBrowser(for: .bonjour(type: Self.service, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let first = results.first else { return }
            Task { @MainActor in self?.resolve(first.endpoint) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                Task { @MainActor in self?.link = .failed(error.localizedDescription) }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// Bonjour gives a service name; a short TCP connection turns it into an address URLSession can use.
    private func resolve(_ endpoint: NWEndpoint) {
        guard resolver == nil else { return }
        var name = "Mac"
        if case let .service(serviceName, _, _, _) = endpoint { name = serviceName }
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = .v4
        }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint else { return }
            var text = "\(host)"
            if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
            connection.cancel()
            Task { @MainActor in
                guard let url = URL(string: "http://\(text):\(port.rawValue)") else { return }
                self?.use(url, name: name)
            }
        }
        connection.start(queue: .main)
        resolver = connection
    }

    private func use(_ url: URL, name: String) {
        base = url
        macName = name
        link = code.count == 6 ? .found(name) : .needsCode
        poll()
    }

    // MARK: talking to it

    private func poll() {
        poller?.cancel()
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func request(_ path: String, body: [String: String]? = nil) -> URLRequest? {
        guard let base else { return nil }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.setValue(code, forHTTPHeaderField: "X-Token")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func refresh() async {
        guard code.count == 6, let req = request("state") else {
            if base != nil { link = .needsCode }
            return
        }
        do {
            let (data, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 {
                link = .needsCode
                return
            }
            state = try JSONDecoder().decode(State.self, from: data)
            link = .connected
        } catch {
            if link == .connected { link = .failed(String(localized: "The Mac stopped answering.")) }
        }
    }

    /// so101-remote's protocol: `J <1..6> <delta>`, `G <gesture>`, `S`, `R`, `V <1..3>`.
    func send(line: String) {
        post(["line": line])
    }

    /// so101-band's actions: next, previous, pose:NAME, routine:NAME, torque, stop.
    func send(action: String) {
        post(["action": action])
    }

    private func post(_ body: [String: String]) {
        guard let req = request("command", body: body) else { return }
        Task {
            _ = try? await session.data(for: req)
            await refresh()
        }
    }

    func jog(_ joint: String, by delta: Double) {
        guard let names = state?.joint_names, let i = names.firstIndex(of: joint) else { return }
        send(line: "J \(i + 1) \(delta)")
    }
}
