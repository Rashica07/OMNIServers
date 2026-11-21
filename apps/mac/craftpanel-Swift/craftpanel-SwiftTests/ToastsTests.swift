import XCTest
@testable import craftpanel_Swift

@MainActor
final class ToastsTests: XCTestCase {
    func testCopyPutsTextOnClipboardAndToasts() {
        let t = Toasts.shared
        let before = t.items.count
        t.copy("play.example.com", what: "Address")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "play.example.com")
        XCTAssertEqual(t.items.count, before + 1)
        XCTAssertEqual(t.items.last?.title, "Address copied")
    }

    func testErrorToastIsMarkedAsError() {
        Toasts.shared.error("Couldn't start", detail: "port busy")
        XCTAssertTrue(Toasts.shared.items.last?.isError ?? false)
    }
}
