import XCTest
@testable import craftpanel_Swift

final class ProblemReportTests: XCTestCase {
    func testRedactsLocalIdentityAndCredentialLines() {
        let input = "User \(NSUserName()) at /Users/someone/server\npassword=secret\nserver started"
        let result = ProblemReport.redact(input, username: NSUserName(), hostname: "test-host", lanIP: "192.168.1.20")
        XCTAssertFalse(result.contains(NSUserName()))
        XCTAssertFalse(result.contains("/Users/someone"))
        XCTAssertFalse(result.contains("password=secret"))
        XCTAssertTrue(result.contains("<credential-like log line removed>"))
        XCTAssertTrue(result.contains("server started"))
    }
}
