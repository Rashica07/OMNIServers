import XCTest
@testable import craftpanel_Swift

/// Direct port of `lock.rs`'s own `#[cfg(test)] mod tests` — same six
/// cases. Never touches `AppLock.shared`'s real Application Support
/// location; each test gets its own temp directory.
final class AppLockTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    /// Returns the lock plus the known `lock.json` path it writes to, so
    /// tests can inspect the raw file the same way the Rust suite does.
    private func tempLock(_ tag: String) -> (AppLock, URL) {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-lock-\(tag)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return (AppLock(configDir: d), d.appending(path: "lock.json"))
    }

    func testNotSetUntilAPINIsSaved() throws {
        let (l, _) = tempLock("unset")
        XCTAssertFalse(l.isSet)
        try l.set(pin: "1234")
        XCTAssertTrue(l.isSet)
    }

    func testRejectsPINsShorterThanMinimum() {
        let (l, _) = tempLock("short")
        XCTAssertThrowsError(try l.set(pin: "12"))
        XCTAssertFalse(l.isSet, "a rejected PIN shouldn't leave a lock file behind")
    }

    func testCorrectPINChecksTrueWrongPINChecksFalse() throws {
        let (l, _) = tempLock("check")
        try l.set(pin: "hunter2")
        XCTAssertTrue(l.check(pin: "hunter2"))
        XCTAssertFalse(l.check(pin: "wrong"))
        XCTAssertFalse(l.check(pin: ""))
    }

    func testCheckingBeforeAPINExistsIsFalseNotACrash() {
        let (l, _) = tempLock("nofile")
        XCTAssertFalse(l.check(pin: "anything"))
    }

    func testClearRequiresTheRightPIN() throws {
        let (l, _) = tempLock("clear")
        try l.set(pin: "correct-horse")
        XCTAssertThrowsError(try l.clear(currentPin: "wrong-guess"))
        XCTAssertTrue(l.isSet, "a failed clear must not remove the lock")
        try l.clear(currentPin: "correct-horse")
        XCTAssertFalse(l.isSet)
    }

    func testHashesAreSaltedNotReusedAcrossPINs() throws {
        // same PIN set twice on two different locks should not produce
        // the same stored file contents — proves a real per-hash salt is
        // in play, not a bare/deterministic digest.
        let (a, pathA) = tempLock("salt-a")
        let (b, pathB) = tempLock("salt-b")
        try a.set(pin: "samepin")
        try b.set(pin: "samepin")
        let contentsA = try String(contentsOf: pathA, encoding: .utf8)
        let contentsB = try String(contentsOf: pathB, encoding: .utf8)
        XCTAssertNotEqual(contentsA, contentsB)
    }
}
