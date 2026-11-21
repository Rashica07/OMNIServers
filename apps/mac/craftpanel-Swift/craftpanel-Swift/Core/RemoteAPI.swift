import Foundation
import Network
import SwiftData
import Observation

/// Port of `remote_api.rs`: a tiny local HTTP API for the Discord bot
/// companion (`bot/`) and the Android app (`mobile/`). Same routes, same
/// JSON shapes, same `remote_api.json` in `~/Library/Application Support/com.craftpanel.app/`
/// (that's where the bot looks for its token), default port 8642.
///
/// Improvements over the Rust version (backport candidates):
/// * **Loopback-only by default.** The bot runs on this Mac and only needs
///   127.0.0.1; listening on every interface is opt-in ("Allow other
///   devices") for the phone app. Rust always bound 0.0.0.0.
/// * Constant-time token comparison (Rust used `==`).
/// * Header/body size limits and a per-connection timeout, so a slow or
///   huge request can't tie the listener up.
/// * Console lines containing CR/LF are rejected — one request can't smuggle
///   several server commands.
/// * The config file is written 0600.
nonisolated struct RemoteAPIConfig: Codable, Equatable, Sendable {
    var enabled = false
    var token = RemoteAPIConfig.newToken()
    var port: UInt16 = 8642
    /// Swift-only field; the bot ignores unknown keys.
    var allowRemote = false

    init() {}

    /// Tolerant decode: a `remote_api.json` written by the Tauri app has no
    /// `allowRemote` key — it must still load (and keep its token).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? Self.newToken()
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? 8642
        allowRemote = try c.decodeIfPresent(Bool.self, forKey: .allowRemote) ?? false
    }

    static func newToken() -> String { "cp_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "com.craftpanel.app/remote_api.json")
    }

    static func load() -> RemoteAPIConfig {
        if let d = try? Data(contentsOf: fileURL), let c = try? JSONDecoder().decode(RemoteAPIConfig.self, from: d) { return c }
        let c = RemoteAPIConfig()
        c.save() // persist so the token doesn't rotate on every read
        return c
    }

    func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = try? JSONEncoder().encode(self) else { return }
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Minimal HTTP/1.1 request parsing — pure, so it's unit-tested.
nonisolated enum MiniHTTP {
    struct Request: Equatable {
        var method: String
        var path: String
        var headers: [String: String] // lowercased names
        var body: Data
    }

    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 64 * 1024

    enum ParseResult: Equatable { case incomplete, tooLarge, bad, done(Request) }

    static func parse(_ buf: Data) -> ParseResult {
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
            return buf.count > maxHeaderBytes ? .tooLarge : .incomplete
        }
        guard end.lowerBound <= maxHeaderBytes,
              let head = String(data: buf[buf.startIndex..<end.lowerBound], encoding: .utf8) else { return .bad }
        var lines = head.components(separatedBy: "\r\n")
        let reqLine = lines.removeFirst().split(separator: " ")
        guard reqLine.count == 3 else { return .bad }
        var headers: [String: String] = [:]
        for l in lines {
            guard let c = l.firstIndex(of: ":") else { return .bad }
            headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let len = Int(headers["content-length"] ?? "0") ?? -1
        guard len >= 0 else { return .bad }
        guard len <= maxBodyBytes else { return .tooLarge }
        let bodyStart = end.upperBound
        guard buf.endIndex - bodyStart >= len else { return .incomplete }
        let path = String(reqLine[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        return .done(Request(method: String(reqLine[0]), path: path, headers: headers,
                             body: Data(buf[bodyStart..<(bodyStart + len)])))
    }

    static func response(_ status: Int, _ json: Any) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                      413: "Payload Too Large", 500: "Internal Server Error"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Authorization, Content-Type\r\n"
        head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    static func tokenMatches(_ header: String?, token: String) -> Bool {
        guard let header, !token.isEmpty else { return false }
        let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        let a = Array(parts[1].utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

@MainActor @Observable
final class RemoteAPIServer {
    static let shared = RemoteAPIServer()
    private(set) var config = RemoteAPIConfig.load()
    private(set) var running = false
    private(set) var lastError: String?

    private var listener: NWListener?
    private var container: ModelContainer?
    private var processes: ProcessManager?
    private let queue = DispatchQueue(label: "craftpanel.remote-api")

    func configure(container: ModelContainer, processes: ProcessManager) {
        self.container = container
        self.processes = processes
        if config.enabled { start() }
    }

    func setEnabled(_ on: Bool) {
        config.enabled = on
        config.save()
        on ? start() : stop()
    }

    func setAllowRemote(_ on: Bool) {
        config.allowRemote = on
        config.save()
        if running { stop(); start() }
    }

    func regenerateToken() {
        config.token = RemoteAPIConfig.newToken()
        config.save()
    }

    /// `{"host","port","token"}` for the phone app's QR pairing.
    func pairPayload() async throws -> String {
        guard running else { throw RconServiceError.message("Turn on the remote API first.") }
        guard config.allowRemote else { throw RconServiceError.message("Turn on “Allow other devices” so your phone can reach this Mac.") }
        guard let ip = await NetworkInfo.publicIP() else {
            throw RconServiceError.message("Couldn't detect your public IP — check your internet connection.")
        }
        let obj: [String: Any] = ["host": ip, "port": Int(config.port), "token": config.token]
        let d = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: d, as: UTF8.self)
    }

    private func start() {
        stop()
        guard let port = NWEndpoint.Port(rawValue: config.port) else { return }
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            if !config.allowRemote {
                params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
            }
            let l = config.allowRemote ? try NWListener(using: params, on: port) : try NWListener(using: params)
            l.newConnectionHandler = { conn in
                Task { @MainActor in RemoteAPIServer.shared.accept(conn) }
            }
            l.stateUpdateHandler = { state in
                Task { @MainActor in
                    let me = RemoteAPIServer.shared
                    switch state {
                    case .ready: me.running = true; me.lastError = nil
                    case .failed(let e): me.running = false; me.lastError = "Couldn't listen on port \(port): \(e.localizedDescription)"
                    case .cancelled: me.running = false
                    default: break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        running = false
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        // Hard cap per connection: slow-loris can't hold it open.
        queue.asyncAfter(deadline: .now() + 10) { conn.cancel() }
        receive(conn, buffer: Data())
    }

    nonisolated private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            switch MiniHTTP.parse(buf) {
            case .incomplete:
                if done || error != nil { conn.cancel() } else { self.receive(conn, buffer: buf) }
            case .tooLarge:
                self.send(conn, MiniHTTP.response(413, ["error": "request too large"]))
            case .bad:
                self.send(conn, MiniHTTP.response(400, ["error": "bad request"]))
            case .done(let req):
                Task { @MainActor in
                    let resp = await self.handle(req)
                    self.send(conn, resp)
                }
            }
        }
    }

    nonisolated private func send(_ conn: NWConnection, _ data: Data) {
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    func handle(_ req: MiniHTTP.Request) async -> Data {
        if req.method == "OPTIONS" { return MiniHTTP.response(204, [:]) }
        guard MiniHTTP.tokenMatches(req.headers["authorization"], token: config.token) else {
            return MiniHTTP.response(401, ["error": "unauthorized"])
        }
        let segs = req.path.split(separator: "/").map(String.init)
        do {
            return MiniHTTP.response(200, try await route(req.method, segs, body: req.body))
        } catch let RouteError.status(code, msg) {
            return MiniHTTP.response(code, ["error": msg])
        } catch {
            return MiniHTTP.response(400, ["error": error.localizedDescription])
        }
    }

    enum RouteError: Error { case status(Int, String) }

    private func record(_ id: String) throws -> ServerRecord {
        guard let container, let uuid = UUID(uuidString: id) else { throw RouteError.status(404, "no such server") }
        let d = FetchDescriptor<ServerRecord>(predicate: #Predicate { $0.id == uuid })
        guard let r = try? container.mainContext.fetch(d).first else { throw RouteError.status(404, "no such server") }
        return r
    }

    private func summarize(_ r: ServerRecord) -> [String: Any] {
        let snap = processes?.runtime(for: r.id).snapshot
        return [
            "id": r.id.uuidString.lowercased(), "name": r.name, "server_type": r.serverType.rawValue,
            "mc_version": r.mcVersion as Any? ?? NSNull(), "ram_mb": Int(r.ramMB),
            "status": snap?.status.rawValue ?? "stopped",
            "pid": snap?.pid.map { Int($0) } as Any? ?? NSNull(),
            "started_at": snap?.startedAt.map { Int($0.timeIntervalSince1970) } as Any? ?? NSNull(),
            "needs_eula": snap?.needsEULA ?? false,
        ]
    }

    private func route(_ method: String, _ segs: [String], body: Data) async throws -> Any {
        guard let processes, let container else { throw RouteError.status(500, "not ready") }
        switch (method, segs.count >= 2 ? Array(segs.prefix(2)) : segs) {
        case ("GET", ["api", "servers"]) where segs.count == 2:
            let all = (try? container.mainContext.fetch(FetchDescriptor<ServerRecord>(sortBy: [SortDescriptor(\.name)]))) ?? []
            return ["servers": all.map(summarize)]
        default: break
        }
        guard segs.count >= 3, segs[0] == "api", segs[1] == "servers" else { throw RouteError.status(404, "not found") }
        let rec = try record(segs[2])
        switch (method, Array(segs.dropFirst(3))) {
        case ("GET", []):
            return summarize(rec)
        case ("POST", ["start"]):
            try processes.start(rec)
            return summarize(rec)
        case ("POST", ["stop"]):
            try processes.stop(rec.id)
            return ["ok": true]
        case ("GET", ["console"]):
            let id = rec.id.uuidString.lowercased()
            return processes.runtime(for: rec.id).lines.map {
                ["server_id": id, "seq": Int($0.id), "stream": $0.stream.rawValue, "level": $0.stream.rawValue, "text": $0.text]
            }
        case ("POST", ["console"]):
            guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let line = obj["line"] as? String else {
                throw RouteError.status(400, "expected a JSON body like {\"line\": \"say hi\"}")
            }
            guard !line.contains(where: { $0 == "\n" || $0 == "\r" }), line.count <= 1000 else {
                throw RouteError.status(400, "one command per request, no line breaks")
            }
            try processes.runtime(for: rec.id).writeStdin(line)
            return ["ok": true]
        case ("GET", ["players"]):
            let p = try await RconService.shared.players(record: rec)
            return ["online": p.online, "max": p.max, "players": p.players]
        default:
            throw RouteError.status(404, "not found")
        }
    }
}
