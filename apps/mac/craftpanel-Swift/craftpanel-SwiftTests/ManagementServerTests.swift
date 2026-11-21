import XCTest
@testable import craftpanel_Swift

/// Direct port of `mgmt.rs`'s own `#[cfg(test)]` module, mirrored
/// test-by-test.
final class ManagementServerTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func makeTempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-mgmt-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    func testVersionGate() {
        XCTAssertTrue(ManagementServer.supports("1.21.9"))
        XCTAssertTrue(ManagementServer.supports("1.21.11"))
        XCTAssertFalse(ManagementServer.supports("1.21.4"))
        XCTAssertFalse(ManagementServer.supports("1.20.1"))
        XCTAssertTrue(ManagementServer.supports("26.2"))
        XCTAssertTrue(ManagementServer.supports("1.22.0"))
        XCTAssertFalse(ManagementServer.supports(nil))
    }

    func testEnableWritesOnlyMgmtKeysAndKeepsOnlineMode() throws {
        let d = makeTempDir()
        try "online-mode=false\nmotd=Hi\nmanagement-server-port=0\n".write(
            to: d.appending(path: "server.properties"), atomically: true, encoding: .utf8
        )

        let st = try ManagementServer.enable(serverDir: d, preferredPort: 25585)
        XCTAssertTrue(st.enabled)
        XCTAssertEqual(st.port, 25585)
        XCTAssertTrue(st.secretSet)

        let out = try String(contentsOf: d.appending(path: "server.properties"), encoding: .utf8)
        XCTAssertTrue(out.contains("online-mode=false")) // untouched
        XCTAssertTrue(out.contains("management-server-enabled=true"))
        XCTAssertTrue(out.contains("motd=Hi"))
    }

    func testEnableWithoutExistingPropertiesFails() {
        let d = makeTempDir()
        XCTAssertThrowsError(try ManagementServer.enable(serverDir: d, preferredPort: 25585))
    }
}
