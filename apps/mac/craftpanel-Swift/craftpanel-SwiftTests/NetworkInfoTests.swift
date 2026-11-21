import XCTest
@testable import craftpanel_Swift

/// Direct port of `net.rs`'s own tests (minus the UPnP-protocol test —
/// this build doesn't port UPnP, see `NetworkInfo`'s doc comment).
final class NetworkInfoTests: XCTestCase {
    func testCGNATDetection() {
        XCTAssertTrue(NetworkInfo.isCGNAT("100.64.0.1"))
        XCTAssertTrue(NetworkInfo.isCGNAT("100.127.255.254"))
        XCTAssertFalse(NetworkInfo.isCGNAT("100.128.0.1"))
        XCTAssertFalse(NetworkInfo.isCGNAT("192.168.1.1"))
        XCTAssertFalse(NetworkInfo.isCGNAT("8.8.8.8"))
    }

    func testInfoReadsPort() throws {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-net-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        try "server-port=25599\n".write(to: d.appending(path: "server.properties"), atomically: true, encoding: .utf8)

        // network calls may no-op in a sandbox; just assert the cheap field
        XCTAssertEqual(NetworkInfo.port(serverDir: d), 25599)
    }

    func testPortDefaultsWhenUnset() throws {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-net-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        XCTAssertEqual(NetworkInfo.port(serverDir: d), 25565)
    }

    func testJavaInviteIncludesVersionAndLANLimit() {
        let text = NetworkInvite.text(serverName: "After School", address: "192.168.1.20:25565",
                                      serverType: .paper, mcVersion: "1.21.4", worksAnywhere: false)
        XCTAssertTrue(text.contains("After School"))
        XCTAssertTrue(text.contains("192.168.1.20:25565"))
        XCTAssertTrue(text.contains("Java Edition 1.21.4"))
        XCTAssertTrue(text.contains("same Wi-Fi or local network"))
    }

    func testBedrockInviteAndSchoolRequestNameProtocolAndPort() {
        let invite = NetworkInvite.text(serverName: "Bedrock", address: "10.0.0.9:19132",
                                        serverType: .bedrock, mcVersion: nil, worksAnywhere: true)
        XCTAssertTrue(invite.contains("Bedrock (port 19132)"))
        XCTAssertTrue(invite.contains("Works from anywhere"))
        let request = NetworkInvite.schoolNetworkRequest(port: 19132, udp: true)
        XCTAssertTrue(request.contains("UDP port 19132"))
        XCTAssertTrue(request.contains("client/AP isolation"))
    }
}
