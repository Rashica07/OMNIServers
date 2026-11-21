import XCTest
@testable import craftpanel_Swift

final class SubprocessTests: XCTestCase {
    /// The old gunzip/zip call sites deadlocked once a pipe passed 64 KB.
    func testLargeStdinAndStdoutDoNotDeadlock() throws {
        let big = Data(repeating: UInt8(ascii: "a"), count: 2_000_000)
        let r = try Subprocess.run("/bin/cat", [], stdin: big, timeout: 20)
        XCTAssertFalse(r.timedOut)
        XCTAssertEqual(r.stdout.count, big.count)
    }

    func testBothStreamsDrainedConcurrently() throws {
        // 300 KB to stderr before anything to stdout.
        let r = try Subprocess.run("/bin/sh", ["-c", "head -c 300000 /dev/zero >&2; echo done"], timeout: 20)
        XCTAssertEqual(r.stderr.count, 300_000)
        XCTAssertEqual(r.stdoutString, "done\n")
    }

    func testTimeoutKillsProcess() throws {
        let t0 = Date()
        let r = try Subprocess.run("/bin/sleep", ["30"], timeout: 0.5)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
    }

    func testGzipRoundTripLargeAndRejectsTruncation() throws {
        let text = (0..<20_000).map { "[12:00:00] [Server thread/INFO]: line \($0)\n" }.joined()
        let one = try Subprocess.run("/usr/bin/gzip", ["-c"], stdin: Data(text.utf8), timeout: 20).stdout
        XCTAssertGreaterThan(text.utf8.count, 64 * 1024)
        XCTAssertEqual(Gzip.decompress(one).map { String(decoding: $0, as: UTF8.self) }, text)
        XCTAssertNil(Gzip.decompress(one.dropLast(20)), "truncated archive must be rejected")
    }

    func testGzipRejectsGarbage() {
        XCTAssertNil(Gzip.decompress(Data("not gzip at all, definitely".utf8)))
    }

    func testLineBufferIsBounded() {
        let b = LineBuffer()
        let out = b.append(Data(repeating: UInt8(ascii: "x"), count: LineBuffer.maxLine + 10))
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(b.flush())
    }
}
