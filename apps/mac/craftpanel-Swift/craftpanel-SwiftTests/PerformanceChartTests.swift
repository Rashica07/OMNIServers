import XCTest
@testable import craftpanel_Swift

final class PerformanceChartTests: XCTestCase {
    func testDownsampleKeepsShortSeriesAndAveragesLongOnes() {
        XCTAssertEqual(PerformanceChart.downsample([1, 2, 3], maxPoints: 10), [1, 2, 3])
        let d = PerformanceChart.downsample(Array(repeating: 10, count: 50) + Array(repeating: 20, count: 50), maxPoints: 2)
        XCTAssertEqual(d, [10, 20])
    }

    func testUptimeFormats() {
        let now = Date()
        XCTAssertEqual(PerformanceChart.uptime(since: nil, now: now), "—")
        XCTAssertEqual(PerformanceChart.uptime(since: now.addingTimeInterval(-42), now: now), "42s")
        XCTAssertEqual(PerformanceChart.uptime(since: now.addingTimeInterval(-125), now: now), "2m 05s")
        XCTAssertEqual(PerformanceChart.uptime(since: now.addingTimeInterval(-(2 * 3600 + 14 * 60)), now: now), "2h 14m")
        XCTAssertEqual(PerformanceChart.uptime(since: now.addingTimeInterval(-(2 * 86400 + 3 * 3600)), now: now), "2d 3h")
    }

    func testLiveRanges() {
        XCTAssertTrue(PerformanceChart.Range.m5.isLive)
        XCTAssertFalse(PerformanceChart.Range.h1.isLive)
    }
}
