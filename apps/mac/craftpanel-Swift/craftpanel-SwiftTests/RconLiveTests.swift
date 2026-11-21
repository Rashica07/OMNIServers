import XCTest
import Darwin
@testable import craftpanel_Swift

/// Live loopback round-trips against a tiny POSIX-socket mock RCON server.
/// These are the tests that used to "hang" — the hang was the old
/// task-group timeout in `RconClient`, not the environment.
final class RconLiveTests: XCTestCase {
    enum Mode { case normal, wrongPassword, silentAfterAuth, emptyPreamble }

    /// Minimal Source-RCON server on 127.0.0.1:<ephemeral>. One client.
    final class MockServer: @unchecked Sendable {
        let port: UInt16
        private let fd: Int32
        private let mode: Mode
        private let password: String

        init(mode: Mode, password: String = "pw") throws {
            self.mode = mode
            self.password = password
            let sfd = socket(AF_INET, SOCK_STREAM, 0)
            var yes: Int32 = 1
            setsockopt(sfd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(sfd, $0, len) } }
            guard bound == 0, Darwin.listen(sfd, 4) == 0 else { throw NSError(domain: "mock", code: 1) }
            _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(sfd, $0, &len) } }
            port = UInt16(bigEndian: addr.sin_port)
            fd = sfd
            Thread.detachNewThread { [self] in serve() }
        }

        func close() { Darwin.close(fd) }

        private func readN(_ c: Int32, _ n: Int) -> [UInt8]? {
            var out = [UInt8](repeating: 0, count: n); var got = 0
            while got < n {
                let r = out.withUnsafeMutableBytes { read(c, $0.baseAddress! + got, n - got) }
                if r <= 0 { return nil }
                got += r
            }
            return out
        }

        private func i32(_ b: ArraySlice<UInt8>) -> Int32 {
            let a = Array(b)
            return Int32(bitPattern: UInt32(a[0]) | UInt32(a[1]) << 8 | UInt32(a[2]) << 16 | UInt32(a[3]) << 24)
        }

        private func send(_ c: Int32, id: Int32, type: Int32, body: String) {
            var p = [UInt8]()
            func le(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { p += $0 } }
            le(Int32(body.utf8.count + 10)); le(id); le(type); p += Array(body.utf8); p += [0, 0]
            _ = p.withUnsafeBytes { write(c, $0.baseAddress!, p.count) }
        }

        private func serve() {
            let c = Darwin.accept(fd, nil, nil)
            guard c >= 0 else { return }
            defer { Darwin.close(c) }
            while let lenB = readN(c, 4) {
                let len = Int(i32(lenB[...]))
                guard let rest = readN(c, len) else { return }
                let id = i32(rest[0..<4]), type = i32(rest[4..<8])
                let body = String(decoding: rest[8..<(len - 2)], as: UTF8.self)
                if type == 3 {
                    if mode == .emptyPreamble { send(c, id: id, type: 0, body: "") }
                    let ok = mode != .wrongPassword && body == password
                    send(c, id: ok ? id : -1, type: 2, body: "")
                } else if mode == .silentAfterAuth {
                    continue
                } else if body == "list" {
                    send(c, id: id, type: 0, body: "There are 1 of a max of 20 players online: Steve")
                } else {
                    send(c, id: id, type: 0, body: "ran: \(body)")
                }
            }
        }
    }

    func testAuthAndCommandRoundTrip() async throws {
        let s = try MockServer(mode: .normal); defer { s.close() }
        let c = try await RconClient.connect(host: "127.0.0.1", port: s.port, password: "pw")
        let out = try await c.command("list")
        XCTAssertEqual(RconClient.parsePlayerList(out).players, ["Steve"])
        let second = try await c.command("say hi")
        XCTAssertEqual(second, "ran: say hi")
        await c.disconnect()
    }

    func testEmptyPreamblePacketBeforeAuthResult() async throws {
        let s = try MockServer(mode: .emptyPreamble); defer { s.close() }
        let c = try await RconClient.connect(host: "127.0.0.1", port: s.port, password: "pw")
        let out = try await c.command("time query daytime")
        XCTAssertEqual(out, "ran: time query daytime")
    }

    func testWrongPasswordFailsWithAuthError() async throws {
        let s = try MockServer(mode: .wrongPassword); defer { s.close() }
        do {
            _ = try await RconClient.connect(host: "127.0.0.1", port: s.port, password: "nope")
            XCTFail("expected auth failure")
        } catch RconError.authFailed {}
    }

    func testRefusedConnectionFailsFastInsteadOfHanging() async throws {
        // Grab a free port, then close it so nothing is listening there.
        let s = try MockServer(mode: .normal); let port = s.port; s.close()
        let t0 = Date()
        do {
            _ = try await RconClient.connect(host: "127.0.0.1", port: port, password: "pw", timeoutSeconds: 3)
            XCTFail("expected failure")
        } catch {}
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3.5)
    }

    func testSilentServerTimesOutInsteadOfHanging() async throws {
        let s = try MockServer(mode: .silentAfterAuth); defer { s.close() }
        let c = try await RconClient.connect(host: "127.0.0.1", port: s.port, password: "pw")
        let t0 = Date()
        do {
            _ = try await c.command("list")
            XCTFail("expected timeout")
        } catch RconError.timedOut {}
        XCTAssertLessThan(Date().timeIntervalSince(t0), 7)
    }

    func testConcurrentCommandsOnOneClientDontInterleave() async throws {
        let s = try MockServer(mode: .normal); defer { s.close() }
        let c = try await RconClient.connect(host: "127.0.0.1", port: s.port, password: "pw")
        let results = try await withThrowingTaskGroup(of: (Int, String).self) { g in
            for i in 0..<8 { g.addTask { (i, try await c.command("say \(i)")) } }
            var r: [Int: String] = [:]
            for try await (i, out) in g { r[i] = out }
            return r
        }
        for i in 0..<8 { XCTAssertEqual(results[i], "ran: say \(i)") }
    }
}
