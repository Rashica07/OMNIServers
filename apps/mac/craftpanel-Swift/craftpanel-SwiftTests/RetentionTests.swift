import XCTest
@testable import craftpanel_Swift

final class RetentionTests: XCTestCase {
    func testTieredKeepsRecentThinsOlderDropsAncient() {
        let now: Int64 = 1_800_000_000
        let h: Int64 = 3600, d: Int64 = 86400
        let items: [(id: String, createdAt: Int64)] = [
            ("recent1", now - 1 * h), ("recent2", now - 5 * h),
            ("d3-early", now - 3 * d - 2 * h), ("d3-late", now - 3 * d + 2 * h),
            ("ancient", now - 90 * d),
        ]
        let keep = Retention.tieredKeepIDs(items, now: now, recentHours: 24, dailyDays: 30)
        XCTAssertTrue(keep.isSuperset(of: ["recent1", "recent2"]))
        XCTAssertFalse(keep.contains("ancient"))
        // exactly one survivor for that older day
        XCTAssertEqual(keep.intersection(["d3-early", "d3-late"]).count, 1)
    }

    func testProtectedIDsKeepOldestNewestAndPinned() {
        let items: [(id: String, createdAt: Int64, pinned: Bool)] = [
            ("oldest", 10, false),
            ("middle", 20, true),
            ("newest", 30, false),
            ("ancient", 1, false),
        ]
        let keep = Retention.protectedIDs(items)
        XCTAssertEqual(keep, ["ancient", "middle", "newest"])
    }

    func testProtectedIDsHandleEmptyInput() {
        XCTAssertTrue(Retention.protectedIDs([]).isEmpty)
    }
}

final class AlertTests: XCTestCase {
    func testEvaluateThresholds() {
        let a = AlertCooldown.evaluate(name: "S", allocMB: 4096, ramMB: 3900, tps: 12.5, freeDiskGB: 1)
        XCTAssertEqual(a.map(\.kind), ["lowTps", "highRam", "lowDisk"])
        XCTAssertTrue(AlertCooldown.evaluate(name: "S", allocMB: 4096, ramMB: 2000, tps: 20, freeDiskGB: 50).isEmpty)
    }

    func testCooldown() {
        var c = AlertCooldown()
        let id = UUID()
        XCTAssertTrue(c.shouldFire(server: id, kind: "lowTps", now: 0))
        XCTAssertFalse(c.shouldFire(server: id, kind: "lowTps", now: 60))
        XCTAssertTrue(c.shouldFire(server: id, kind: "highRam", now: 60))
        XCTAssertTrue(c.shouldFire(server: id, kind: "lowTps", now: AlertCooldown.cooldownSecs))
    }
}
