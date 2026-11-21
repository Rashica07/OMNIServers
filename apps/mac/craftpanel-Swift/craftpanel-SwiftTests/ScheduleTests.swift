import XCTest
@testable import craftpanel_Swift

/// Direct port of `schedule.rs`'s own `#[cfg(test)] mod tests` — same
/// four cases, same edge values.
final class ScheduleTests: XCTestCase {
    private func server() -> ServerRecord {
        ServerRecord(name: "srv1", path: "/tmp/srv1", serverType: .vanilla, launchTarget: "server.jar", mcVersion: nil, javaPath: "java", ramMB: 4096)
    }

    func testIsDefaultAccountsForTheNewBackupFields() {
        XCTAssertTrue(Schedule().isDefault)

        var s = Schedule(); s.intervalBackupHours = 6
        XCTAssertFalse(s.isDefault)

        s = Schedule(); s.scheduledStart = "06:00"
        XCTAssertFalse(s.isDefault)

        // 0 hours is the same as "off", same as nil
        s = Schedule(); s.intervalBackupHours = 0
        XCTAssertTrue(s.isDefault)

        s = Schedule(); s.snapshotIntervalMins = 15
        XCTAssertFalse(s.isDefault)

        s = Schedule(); s.snapshotIntervalMins = 0
        XCTAssertTrue(s.isDefault)
    }

    func testSnapshotRetentionDefaultsApplyOnlyWhenUnset() {
        let s = Schedule()
        XCTAssertEqual(s.snapshotRecentHours, 24)
        XCTAssertEqual(s.snapshotDailyDays, 30)

        var s2 = Schedule()
        s2.snapshotKeepRecentHours = 6
        s2.snapshotKeepDailyDays = 7
        XCTAssertEqual(s2.snapshotRecentHours, 6)
        XCTAssertEqual(s2.snapshotDailyDays, 7)
    }

    func testParsesTimes() {
        XCTAssertEqual(ScheduleStore.parseHHMM("04:00")?.0, 4)
        XCTAssertEqual(ScheduleStore.parseHHMM("04:00")?.1, 0)
        XCTAssertEqual(ScheduleStore.parseHHMM("23:59")?.0, 23)
        XCTAssertEqual(ScheduleStore.parseHHMM("23:59")?.1, 59)
        XCTAssertNil(ScheduleStore.parseHHMM("24:00"))
        XCTAssertEqual(ScheduleStore.parseHHMM("4:5")?.0, 4)
        XCTAssertEqual(ScheduleStore.parseHHMM("4:5")?.1, 5)
        XCTAssertNil(ScheduleStore.parseHHMM("nope"))
    }

    func testScheduleJSONRoundtripsAndValidates() throws {
        let rec = server()
        var s = Schedule()
        s.restartOnCrash = true
        s.dailyRestart = "04:30"
        s.backupOnStop = true
        s.intervalBackupHours = 12
        s.timedCommands = [TimedCommand(at: "03:00", command: "save-all")]

        try ScheduleStore.write(rec, s)
        let back = ScheduleStore.read(rec)
        XCTAssertTrue(back.restartOnCrash)
        XCTAssertEqual(back.dailyRestart, "04:30")
        XCTAssertEqual(back.timedCommands.count, 1)
        XCTAssertEqual(back.intervalBackupHours, 12)

        s.dailyRestart = "99:99"
        XCTAssertThrowsError(try ScheduleStore.write(rec, s))

        XCTAssertTrue(ScheduleStore.read(server()).isDefault)
    }

    func testOnStartCommandsRoundTripAndOldJSONStillDecodes() throws {
        var sch = Schedule(); sch.onStartCommands = ["gamerule keepInventory true"]
        XCTAssertFalse(sch.isDefault)
        let back = try JSONDecoder().decode(Schedule.self, from: JSONEncoder().encode(sch))
        XCTAssertEqual(back.onStartCommands, ["gamerule keepInventory true"])
        let old = try JSONEncoder().encode(Schedule())
        XCTAssertNil(try JSONDecoder().decode(Schedule.self, from: old).onStartCommands)
        XCTAssertTrue(Schedule().isDefault)
    }
}
