import XCTest
@testable import craftpanel_Swift

/// Direct port of `CommandPalette.tsx`'s `score` fuzzy-match function —
/// no Rust equivalent exists (this is a frontend-only feature), so these
/// mirror the JS behavior instead of a Rust test suite.
final class CommandPaletteTests: XCTestCase {
    func testEmptyQueryMatchesEverything() {
        XCTAssertEqual(CommandPalette.score("", "Console"), 1)
    }

    func testExactMatchScoresHighest() {
        XCTAssertEqual(CommandPalette.score("console", "Console"), 100)
    }

    func testPrefixBeatsSubstring() {
        XCTAssertEqual(CommandPalette.score("con", "Console"), 80)
        XCTAssertEqual(CommandPalette.score("sole", "Console"), 60)
    }

    func testInOrderSubsequenceMatches() {
        XCTAssertEqual(CommandPalette.score("cnl", "Console"), 20)
    }

    func testNoMatchScoresZero() {
        XCTAssertEqual(CommandPalette.score("xyz", "Console"), 0)
    }
}
