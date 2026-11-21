import XCTest
@testable import craftpanel_Swift

final class PerfSamplerTests: XCTestCase {
    func testParsesVanillaTickOutput() {
        let out = "Target tick rate: 20.0 per second.\nAverage time per tick: 2.5ms (Target: 50.0ms)"
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        let mspt = lines.first { $0.contains("per tick") }.flatMap { PerfSampler.numAfterColon(String($0)) }
        XCTAssertEqual(mspt, 2.5)
        let tps = lines.first { $0.contains("tick rate") }.flatMap { PerfSampler.numAfterColon(String($0)) }
        XCTAssertEqual(tps, 20.0)
    }

    func testParsesPaperTPSLine() {
        let out = "\u{a7}6TPS from last 1m, 5m, 15m: \u{a7}a19.98, \u{a7}a20.0, \u{a7}a20.0"
        XCTAssertEqual(PerfSampler.numAfterColon(PerfSampler.stripColor(out)), 19.98)
    }

    func testOwnProcessReportsMemory() {
        let (ram, _) = PerfSampler.processSample(pid: ProcessInfo.processInfo.processIdentifier)
        XCTAssertTrue((ram ?? 0) > 0)
    }

    func testFirstNumStopsAtNonNumeric() {
        XCTAssertEqual(PerfSampler.firstNum("2.5ms"), 2.5)
        XCTAssertEqual(PerfSampler.firstNum("-3.0"), -3.0)
        XCTAssertNil(PerfSampler.firstNum("no digits here"))
    }

    func testStripColorRemovesSectionCodes() {
        XCTAssertEqual(PerfSampler.stripColor("\u{a7}aGreen\u{a7}rReset"), "GreenReset")
        XCTAssertEqual(PerfSampler.stripColor("plain"), "plain")
    }
}
