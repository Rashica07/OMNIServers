import XCTest
@testable import craftpanel_Swift

/// `RconClient`'s wire protocol (packet framing, auth handshake, command
/// draining) is a direct byte-for-byte port of `rcon.rs`'s binary framing
/// — reviewed line-by-line against the Rust source rather than assumed.
///
/// Live-socket coverage lives in `RconLiveTests` (the earlier "environment
/// hang" was the old task-group timeout bug in `RconClient`).
final class RconClientTests: XCTestCase {
    func testParsesPlayerList() {
        let (on, max, players) = RconClient.parsePlayerList("There are 2 of a max of 20 players online: Alice, Bob")
        XCTAssertEqual(on, 2)
        XCTAssertEqual(max, 20)
        XCTAssertEqual(players, ["Alice", "Bob"])
    }

    func testParsesEmptyPlayerList() {
        let (on, max, players) = RconClient.parsePlayerList("There are 0 of a max of 20 players online:")
        XCTAssertEqual(on, 0)
        XCTAssertEqual(max, 20)
        XCTAssertTrue(players.isEmpty)
    }

    func testParsesTrailingPeriodsOffNames() {
        // Some server builds render the list with a trailing '.' —
        // matches the Rust source's `trim_end_matches('.')` handling.
        let (_, _, players) = RconClient.parsePlayerList("There are 1 of a max of 20 players online: Steve.")
        XCTAssertEqual(players, ["Steve"])
    }

}
