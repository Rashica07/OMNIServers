import Foundation

/// Keeps one authenticated connection per server and reuses it, so
/// polling (players, later TPS/RAM) doesn't reconnect every few seconds.
/// Reconnects on error. Direct port of `rcon.rs`'s `RconPool`.
///
/// An `actor` gives each server's slot the same isolation Rust achieved
/// with a per-server `Arc<Mutex<Option<RconClient>>>` inside an outer map
/// lock only ever held for the dictionary lookup — a slow or hung RCON
/// call against one server can't delay a command to any other server,
/// since each `run` call only ever awaits its own key's prior work via
/// normal actor serialization, not a shared lock.
actor RconPool {
    private var clients: [UUID: RconClient] = [:]
    /// In-flight connects, so concurrent first calls for one server share
    /// a single connection instead of racing to open several.
    private var connecting: [UUID: Task<RconClient, Error>] = [:]

    /// Run `body` against the pooled connection for `key`; on any error,
    /// drop it and retry once on a fresh connection.
    func run<T: Sendable>(
        key: UUID,
        host: String,
        port: UInt16,
        password: String,
        _ body: @Sendable (RconClient) async throws -> T
    ) async throws -> T {
        if let existing = clients[key] {
            do {
                return try await body(existing)
            } catch {
                // Don't leak the NWConnection of a client we're throwing away.
                if clients[key] === existing { clients[key] = nil }
                await existing.disconnect()
            }
        }
        let client = try await client(for: key, host: host, port: port, password: password)
        do {
            return try await body(client)
        } catch {
            if clients[key] === client { clients[key] = nil }
            await client.disconnect()
            throw error
        }
    }

    private func client(for key: UUID, host: String, port: UInt16, password: String) async throws -> RconClient {
        if let c = clients[key], await !c.isClosed { return c }
        if let pending = connecting[key] { return try await pending.value }
        let task = Task { try await RconClient.connect(host: host, port: port, password: password) }
        connecting[key] = task
        defer { connecting[key] = nil }
        let c = try await task.value
        clients[key] = c
        return c
    }

    /// Hangs up and waits for it — used when a server is shutting down, which waits for its RCON client threads to finish.
    func closeConnection(key: UUID) async {
        if let client = clients.removeValue(forKey: key) { await client.disconnect() }
    }

    func dropConnection(key: UUID) {
        if let client = clients.removeValue(forKey: key) {
            Task { await client.disconnect() }
        }
    }
}
