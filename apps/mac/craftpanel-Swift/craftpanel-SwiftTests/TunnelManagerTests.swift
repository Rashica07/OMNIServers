import XCTest
@testable import craftpanel_Swift

/// Direct port of `tunnel.rs`'s own ANSI-stripping test.
final class TunnelManagerTests: XCTestCase {
    func testParsesBoreListeningLineWithANSI() {
        let line = "\u{1b}[2m2026..\u{1b}[0m \u{1b}[32m INFO\u{1b}[0m \u{1b}[2mbore_cli::client\u{1b}[0m\u{1b}[2m:\u{1b}[0m listening at bore.pub:38561\u{1b}[0m"
        let clean = TunnelManager.stripANSI(line)
        let addr = clean.range(of: "listening at ").map { clean[$0.upperBound...] }
            .flatMap { $0.split(separator: " ").first }
            .map(String.init)
        XCTAssertEqual(addr, "bore.pub:38561")
    }

    func testStripANSILeavesPlainTextUntouched() {
        XCTAssertEqual(TunnelManager.stripANSI("listening at bore.pub:1234"), "listening at bore.pub:1234")
    }
}
