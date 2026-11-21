import XCTest
@testable import craftpanel_Swift

final class LidSleepTests: XCTestCase {
    func testReadsSleepDisabledFromPmset() {
        XCTAssertTrue(LidSleep.parseDisabled(" sleep 1\n SleepDisabled\t\t1\n displaysleep 10"))
        XCTAssertFalse(LidSleep.parseDisabled(" SleepDisabled\t\t0\n"))
        XCTAssertFalse(LidSleep.parseDisabled("nothing relevant"))
    }
    func testCommandsToggleDisablesleep() {
        XCTAssertEqual(LidSleep.command(disable: true), "/usr/bin/pmset -a disablesleep 1")
        XCTAssertEqual(LidSleep.command(disable: false), "/usr/bin/pmset -a disablesleep 0")
    }
}
