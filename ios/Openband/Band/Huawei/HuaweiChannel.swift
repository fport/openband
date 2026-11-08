import Foundation

// Request/response over any byte transport. The band answers each request with a message
// carrying the same service and command ids; anything else that arrives (battery changes,
// band-initiated requests) goes to `onUnsolicited`. Sans-IO port of the Band class in
// openband/link.py: the owner feeds notification bytes into `receive` and supplies `write`.

enum HuaweiError: Error, Equatable, CustomStringConvertible {
    case timeout(HuaweiCommandID, seconds: Double)
    case refused(HuaweiCommandID, code: Int)
    case disconnected
    case noSessionKey
    case needsBond(String)
    case needsBandMAC
    case hiChainUnsupported(Int)
    case badChallenge
    case unexpected(String)

    var description: String {
        switch self {
        case let .timeout(id, seconds): return "no answer to \(id) within \(Int(seconds))s"
        case let .refused(id, code): return "band refused \(id) with error \(code)"
        case .disconnected: return "the band disconnected"
        case .noSessionKey: return "no session key yet"
        case .needsBond(let message): return message
        case .needsBandMAC:
            return "this band uses normal-mode bonding, which needs its Bluetooth MAC (Settings > About on the band)"
        case .hiChainUnsupported(let type):
            return String(format: "the band wants full HiChain pairing (auth type 0x%x), which Openband does not speak yet", type)
        case .badChallenge: return "the band's answer to our challenge does not check out"
        case .unexpected(let message): return message
        }
    }
}

@MainActor
final class HuaweiChannel {
    let session: HuaweiSession
    /// Largest write the transport takes in one go; packets are sliced to fit.
    var maxWrite: Int
    let defaultTimeout: TimeInterval
    /// Messages nobody asked for, already decrypted.
    var onUnsolicited: ((HuaweiMessage, HuaweiTLV) -> Void)?
    /// Diagnostics: every request and answer, and anything dropped.
    var onLog: ((String) -> Void)?

    private let write: @MainActor (Data) async throws -> Void
    private var reassembler = HuaweiReassembler()
    private struct Waiter {
        let token: Int
        let continuation: CheckedContinuation<HuaweiTLV, Error>
        var timer: Task<Void, Never>?
    }
    private var waiting: [HuaweiCommandID: Waiter] = [:]
    private var nextToken = 0
    private var locked = false
    private var lockQueue: [CheckedContinuation<Void, Never>] = []
    private(set) var closed: Error?

    init(session: HuaweiSession, maxWrite: Int, write: @escaping @MainActor (Data) async throws -> Void,
         defaultTimeout: TimeInterval = 8) {
        self.session = session
        self.maxWrite = maxWrite
        self.write = write
        self.defaultTimeout = defaultTimeout
    }

    // MARK: receiving

    func receive(_ chunk: Data) {
        let messages: [HuaweiMessage]
        do {
            messages = try reassembler.feed(chunk)
        } catch {
            onLog?("dropping bad frame: \(error)")
            return
        }
        for m in messages { handle(m) }
    }

    private func handle(_ m: HuaweiMessage) {
        let id = HuaweiCommandID(service: m.service, command: m.command)
        let body: HuaweiTLV
        do {
            body = try session.open(try HuaweiTLV.parse(m.body))
        } catch {
            onLog?("cannot read \(id): \(error) (\(huaweiHex(m.body)))")
            return
        }
        onLog?("<< \(id) \(body)")
        if waiting[id] != nil {
            resolve(id, token: nil, .success(body))
            return
        }
        onUnsolicited?(m, body)
    }

    /// Fails every pending request (e.g. on disconnect) and every later one.
    func fail(_ error: Error) {
        closed = error
        for id in Array(waiting.keys) { resolve(id, token: nil, .failure(error)) }
    }

    private func resolve(_ id: HuaweiCommandID, token: Int?, _ result: Result<HuaweiTLV, Error>) {
        guard let waiter = waiting[id], token == nil || waiter.token == token else { return }
        waiting[id] = nil
        waiter.timer?.cancel()
        waiter.continuation.resume(with: result)
    }

    // MARK: sending

    func packets(for request: HuaweiRequest) throws -> [Data] {
        let body = request.encrypted ? try session.seal(request.tlv) : request.tlv
        let sliceSize = min(session.params.sliceSize, maxWrite)
        return try HuaweiFrame.encode(service: request.service, command: request.command, body: body.serialize(), sliceSize: sliceSize)
    }

    func send(_ request: HuaweiRequest) async throws {
        if let closed { throw closed }
        onLog?(">> \(request.id) \(request.tlv)\(request.encrypted ? " (sealed)" : "")")
        for packet in try packets(for: request) {
            var offset = 0
            while offset < packet.count {
                let end = min(offset + max(maxWrite, 1), packet.count)
                try await write(packet.subdata(in: offset ..< end))
                offset = end
            }
        }
    }

    /// Sends one request and waits for the band's answer to the same service and command.
    /// Requests run one at a time, in call order.
    func request(_ request: HuaweiRequest, timeout: TimeInterval? = nil) async throws -> HuaweiTLV {
        await acquire()
        defer { release() }
        if let closed { throw closed }
        let id = request.id
        let seconds = timeout ?? defaultTimeout
        nextToken += 1
        let token = nextToken
        let body: HuaweiTLV = try await withCheckedThrowingContinuation { continuation in
            var waiter = Waiter(token: token, continuation: continuation, timer: nil)
            waiter.timer = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.resolve(id, token: token, .failure(HuaweiError.timeout(id, seconds: seconds)))
            }
            waiting[id] = waiter
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.send(request)
                } catch {
                    self.resolve(id, token: token, .failure(error))
                }
            }
        }
        if body.contains(HuaweiSession.tagResult), body.items.count == 1 {
            let code = body.uint(HuaweiSession.tagResult, default: 0)
            if code != HuaweiSession.resultSuccess { throw HuaweiError.refused(id, code: code) }
        }
        return body
    }

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { lockQueue.append($0) }
    }

    private func release() {
        if lockQueue.isEmpty {
            locked = false
        } else {
            lockQueue.removeFirst().resume()
        }
    }
}
