import XCTest
@testable import craftpanel_Swift

/// Direct port of `share.rs`'s own `#[cfg(test)] mod tests`.
final class ShareLeaseTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func tempDir(_ tag: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-share-\(tag)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    func testCodeHasNoLookalikes() {
        let c = ShareLease.genCode()
        XCTAssertEqual(c.count, 9) // XXXX-XXXX
        XCTAssertFalse(c.contains("0") || c.contains("O") || c.contains("1") || c.contains("I"))
    }

    func testLeaseLifecycleAndConflict() throws {
        let d = tempDir("lifecycle")
        try ShareLease.createShare(dir: d, name: "Test")

        // device A claims
        try ShareLease.claim(dir: d, deviceID: "A", force: false)
        let v = ShareLease.view(dir: d, deviceID: "A")
        XCTAssertTrue(v.shared && v.locked && v.heldByUs)

        // device B is refused while A's lease is live
        XCTAssertThrowsError(try ShareLease.claim(dir: d, deviceID: "B", force: false)) { error in
            XCTAssertTrue(error.localizedDescription.contains("In use"))
        }

        // B can force
        try ShareLease.claim(dir: d, deviceID: "B", force: true)
        XCTAssertFalse(ShareLease.view(dir: d, deviceID: "A").heldByUs)
        XCTAssertTrue(ShareLease.view(dir: d, deviceID: "B").heldByUs)

        // B releases; now A can claim freely
        ShareLease.release(dir: d, deviceID: "B")
        XCTAssertFalse(ShareLease.view(dir: d, deviceID: "A").locked)
        try ShareLease.claim(dir: d, deviceID: "A", force: false)
    }

    func testStaleLeaseIsTakeable() throws {
        let d = tempDir("stale")
        try ShareLease.createShare(dir: d, name: "Test")
        let now = Int64(Date().timeIntervalSince1970)
        let stale = Lease(holder: "ghost", hostname: "old-laptop", claimedAt: now - 10_000, expiresAt: now - 5_000)
        let encoder = JSONEncoder()
        try encoder.encode(stale).write(to: d.appending(path: ShareLease.leaseFile))

        // not forced, but it's expired -> allowed
        try ShareLease.claim(dir: d, deviceID: "me", force: false)
        XCTAssertTrue(ShareLease.view(dir: d, deviceID: "me").heldByUs)
    }

    func testDoubleShareIsRejected() throws {
        let d = tempDir("double")
        try ShareLease.createShare(dir: d, name: "Test")
        XCTAssertThrowsError(try ShareLease.createShare(dir: d, name: "Test"))
    }
}
