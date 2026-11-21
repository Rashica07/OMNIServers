import Foundation
import Network

/// Direct port of `rcon.rs`'s error type.
nonisolated enum RconError: Error, LocalizedError, Sendable {
    case io(String)
    case authFailed
    case protocolError(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .io(let s): "connection error: \(s)"
        case .authFailed: "RCON password rejected"
        case .protocolError(let s): "RCON protocol error: \(s)"
        case .timedOut: "RCON read timed out"
        }
    }
}

/// Minimal Source RCON client — the protocol Minecraft speaks, over
/// `Network.framework`.
///
/// Transport design (rewritten 2026-09 — the previous version raced each
/// `NWConnection.receive` against a `Task.sleep` inside a task group; a task
/// group waits for *all* children and a checked continuation ignores
/// cancellation, so every timeout turned into a permanent hang):
///
/// * one `receive` is always in flight; its data is appended to `buffer`
///   and the next `receive` is only issued after the actor has stored the
///   chunk, so chunks can never be reordered;
/// * a reader waits on `waiter`, which is resumed by new data, by the
///   connection closing, or by a per-wait timer. A timeout only abandons the
///   *wait* — the connection and its buffered bytes stay valid, which is
///   what the 250 ms "drain" phase of `command` relies on.
actor RconClient {
    private let connection: NWConnection
    private var nextID: Int32 = 1
    private var buffer = Data()
    private var closedError: RconError?
    private var waiter: CheckedContinuation<Void, Error>?
    private var waiterToken = 0

    private static let typeAuth: Int32 = 3
    private static let typeExec: Int32 = 2
    private static let typeResponse: Int32 = 0
    private static let maxBody = 4096

    private init(connection: NWConnection) {
        self.connection = connection
    }

    static func connect(host: String, port: UInt16, password: String, timeoutSeconds: Double = 3) async throws -> RconClient {
        guard let nwPort = NWEndpoint.Port(rawValue: port), port != 0 else {
            throw RconError.protocolError("invalid port \(port)")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        try await waitReady(connection, timeoutSeconds: timeoutSeconds)

        let client = RconClient(connection: connection)
        await client.pump()
        do {
            try await client.authenticate(password: password)
        } catch {
            connection.cancel()
            throw error
        }
        return client
    }

    /// Start the connection and wait for `.ready`. `.waiting` (e.g. ECONNREFUSED
    /// — nothing listening) fails immediately rather than retrying forever; the
    /// timeout cancels the connection, which resumes the continuation exactly once.
    private static func waitReady(_ connection: NWConnection, timeoutSeconds: Double) async throws {
        let once = ResumeOnce()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            once.set(cont)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(nil)
                case .waiting(let err), .failed(let err):
                    once.resume(RconError.io(err.debugDescription))
                    connection.cancel()
                case .cancelled:
                    once.resume(RconError.timedOut)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds) {
                if once.resume(RconError.timedOut) { connection.cancel() }
            }
        }
        connection.stateUpdateHandler = { _ in }
    }

    private func authenticate(password: String) async throws {
        let id = takeID()
        try await sendPacket(id: id, type: Self.typeAuth, body: password)
        // Server may send an empty RESPONSE_VALUE first, then the auth result.
        while true {
            let pkt = try await recvPacket()
            if pkt.type == Self.typeExec || pkt.type == Self.typeResponse {
                if pkt.id == -1 { throw RconError.authFailed }
                if pkt.id == id { return }
                // ignore the leading empty packet, keep reading
            }
        }
    }

    /// Run a command and return its text output.
    ///
    /// Minecraft sends one RESPONSE_VALUE per command for anything short
    /// (which is every command OMNIServers issues). Read that packet, then
    /// briefly drain any continuation packets for long output like
    /// `help`. Deliberately doesn't send the Source-style "sentinel"
    /// follow-up packet — Paper closes the connection on it.
    func command(_ cmd: String) async throws -> String {
        // Actor methods are reentrant across `await`; without this, two
        // concurrent callers would interleave reads on one socket.
        await acquire()
        defer { release() }
        let id = takeID()
        try await sendPacket(id: id, type: Self.typeExec, body: cmd)

        var body = ""
        // Skip stale responses (e.g. a late reply to an earlier, timed-out command).
        while true {
            let pkt = try await recvPacket()
            if pkt.id == id { body += pkt.body; break }
        }
        // Continuation packets only exist when the first one was full.
        guard body.utf8.count >= Self.maxBody - 10 else { return body }
        while true {
            do {
                let pkt = try await recvPacket(timeoutSeconds: 0.25)
                if pkt.id == id { body += pkt.body }
            } catch RconError.timedOut {
                return body
            }
        }
    }

    private var busy = false
    private var queued: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { queued.append($0) }
    }

    private func release() {
        if queued.isEmpty { busy = false } else { queued.removeFirst().resume() }
    }

    private func takeID() -> Int32 {
        let id = nextID
        nextID = nextID == Int32.max ? 1 : nextID + 1
        return id
    }

    private func sendPacket(id: Int32, type: Int32, body: String) async throws {
        let bodyBytes = Array(body.utf8)
        guard bodyBytes.count <= Self.maxBody else {
            throw RconError.protocolError("command too long")
        }
        var buf = Data()
        let len = Int32(bodyBytes.count + 10)
        buf.append(Self.littleEndianBytes(len))
        buf.append(Self.littleEndianBytes(id))
        buf.append(Self.littleEndianBytes(type))
        buf.append(contentsOf: bodyBytes)
        buf.append(contentsOf: [0, 0])
        try await sendRaw(buf)
    }

    private struct Packet {
        let id: Int32
        let type: Int32
        let body: String
    }

    /// Read one packet. A timeout never consumes a partial packet: bytes are
    /// only removed from `buffer` once the whole frame is present.
    private func recvPacket(timeoutSeconds: Double = 5) async throws -> Packet {
        let deadline = ContinuousClock.now + .seconds(timeoutSeconds)
        try await waitForBytes(4, until: deadline)
        let len = Self.readLittleEndianInt32(buffer.prefix(4))
        guard (10...(Int32(Self.maxBody) + 10)).contains(len) else {
            closedError = .protocolError("bad packet length \(len)")
            connection.cancel()
            throw closedError!
        }
        try await waitForBytes(4 + Int(len), until: deadline)
        let frame = Data(buffer.prefix(4 + Int(len)))
        buffer.removeFirst(4 + Int(len))
        let rest = frame.dropFirst(4)
        let id = Self.readLittleEndianInt32(rest.prefix(4))
        let type = Self.readLittleEndianInt32(rest.dropFirst(4).prefix(4))
        let bodyBytes = rest.dropFirst(8).dropLast(2)
        return Packet(id: id, type: type, body: String(decoding: bodyBytes, as: UTF8.self))
    }

    // MARK: - Raw transport

    private func waitForBytes(_ n: Int, until deadline: ContinuousClock.Instant) async throws {
        while buffer.count < n {
            if let closedError { throw closedError }
            let remaining = deadline - ContinuousClock.now
            if remaining <= .zero { throw RconError.timedOut }
            waiterToken &+= 1
            let token = waiterToken
            Task { [weak self] in
                try? await Task.sleep(for: remaining)
                await self?.expireWaiter(token)
            }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                waiter = cont
            }
        }
    }

    private func expireWaiter(_ token: Int) {
        guard token == waiterToken, let w = waiter else { return }
        waiter = nil
        w.resume(throwing: RconError.timedOut)
    }

    private func wakeWaiter() {
        guard let w = waiter else { return }
        waiter = nil
        w.resume()
    }

    /// Keep exactly one `receive` outstanding for the life of the connection.
    private func pump() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { await self?.ingest(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func ingest(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty { buffer.append(data) }
        if let error {
            closedError = .io(error.debugDescription)
        } else if isComplete {
            closedError = .io("connection closed")
        }
        wakeWaiter()
        if closedError == nil { pump() }
    }

    private func sendRaw(_ data: Data) async throws {
        if let closedError { throw closedError }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: RconError.io(error.debugDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    var isClosed: Bool { closedError != nil }

    func disconnect() {
        closedError = closedError ?? .io("disconnected")
        connection.cancel()
        wakeWaiter()
    }

    private static func littleEndianBytes(_ v: Int32) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }

    private static func readLittleEndianInt32<D: DataProtocol>(_ d: D) -> Int32 {
        let b = Array(d.prefix(4))
        return Int32(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
    }

    // MARK: - Higher-level helpers the admin layer uses

    /// Parse the vanilla `/list` output into player names.
    ///
    /// "There are 2 of a max of 20 players online: Alice, Bob"
    nonisolated static func parsePlayerList(_ output: String) -> (online: Int, max: Int, players: [String]) {
        var online = 0
        var max = 0
        var players: [String] = []

        if let range = output.range(of: "There are ") {
            let rest = output[range.upperBound...]
            let tokens = rest.split(separator: " ", omittingEmptySubsequences: true)
            if let first = tokens.first, let n = Int(first) { online = n }
            // "... of a max of N players online:" -- keep reading until
            // the first further integer token, same as the Rust source.
            for w in tokens.dropFirst() {
                if let n = Int(w) { max = n; break }
            }
        }
        if let range = output.range(of: "online:") {
            let names = output[range.upperBound...]
            players = names.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .map { name -> String in
                    var s = name
                    while s.hasSuffix(".") { s.removeLast() }
                    return s
                }
                .filter { !$0.isEmpty }
        }
        return (online, max, players)
    }
}

/// Resumes a continuation at most once, from whichever callback gets there first.
nonisolated final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Error>?
    private var done = false

    func set(_ c: CheckedContinuation<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        cont = c
    }

    /// Returns true if this call did the resuming.
    @discardableResult
    func resume(_ error: Error?) -> Bool {
        lock.lock()
        guard !done, let c = cont else { lock.unlock(); return false }
        done = true
        cont = nil
        lock.unlock()
        if let error { c.resume(throwing: error) } else { c.resume() }
        return true
    }
}
