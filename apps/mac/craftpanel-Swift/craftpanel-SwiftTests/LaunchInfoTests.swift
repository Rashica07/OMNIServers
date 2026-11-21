import XCTest
@testable import craftpanel_Swift

final class LaunchInfoTests: XCTestCase {
    func testAddressUsesLanIPOrFallsBackToLocalhost() {
        XCTAssertEqual(LaunchInfo.address(lanIP: "192.168.1.24", port: 25565), "192.168.1.24:25565")
        XCTAssertEqual(LaunchInfo.address(lanIP: nil, port: 19132), "localhost:19132")
    }

    func testInviteHasNameAddressAndVersion() {
        let t = LaunchInfo.inviteText(name: "Survival", address: "10.0.0.2:25565", version: "1.21.4")
        XCTAssertTrue(t.contains("\"Survival\"") && t.contains("10.0.0.2:25565") && t.contains("Minecraft 1.21.4"))
        XCTAssertFalse(LaunchInfo.inviteText(name: "A", address: "x:1", version: nil).contains("Game:"))
    }

    func testChecklistFollowsRealStatus() {
        XCTAssertTrue(LaunchInfo.steps(for: .stopped).isEmpty)
        let s = LaunchInfo.steps(for: .starting)
        XCTAssertTrue(s[0].done && s[1].active && !s[2].done)
        XCTAssertTrue(LaunchInfo.steps(for: .running).allSatisfy { $0.done })
    }
}

import Testing
@testable import craftpanel_Swift

struct BestAddressTests {
    @Test func savedAddressWins() { #expect(LaunchInfo.bestAddress(manual: " play.example.gg ", tunnel: "bore.pub:1", lan: "192.168.1.5:25565") == "play.example.gg") }
    @Test func tunnelBeatsLan() { #expect(LaunchInfo.bestAddress(manual: "", tunnel: "bore.pub:1", lan: "192.168.1.5:25565") == "bore.pub:1") }
    @Test func fallsBackToLan() { #expect(LaunchInfo.bestAddress(manual: nil, tunnel: nil, lan: "192.168.1.5:25565") == "192.168.1.5:25565") }
}
