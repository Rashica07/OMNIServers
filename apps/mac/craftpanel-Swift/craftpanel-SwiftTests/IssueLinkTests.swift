import XCTest
@testable import craftpanel_Swift

final class IssueLinkTests: XCTestCase {
    func testLinkCarriesRedactedLogAndStaysShort() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appending(path: "logs"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lines = (0..<400).map { "line \($0) /Users/\(NSUserName())/x" + ($0 == 390 ? " password=hunter2" : "") }
        try lines.joined(separator: "\n").write(to: dir.appending(path: "logs/latest.log"), atomically: true, encoding: .utf8)

        let tail = IssueLink.logTail(serverPath: dir.path)
        XCTAssertFalse(tail.contains("hunter2"))
        XCTAssertTrue(tail.contains("line 399"))
        XCTAssertFalse(tail.contains("line 100 "))

        let url = try XCTUnwrap(IssueLink.url(version: "2.8.2", log: tail))
        XCTAssertLessThanOrEqual(url.absoluteString.count, 7100)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://github.com/Rashica07/OMNIServers/issues/new?body="))
        XCTAssertEqual(IssueLink.logTail(serverPath: dir.appending(path: "nope").path), "")
        XCTAssertEqual(IssueLink.logTail(serverPath: nil), "")
    }
}
