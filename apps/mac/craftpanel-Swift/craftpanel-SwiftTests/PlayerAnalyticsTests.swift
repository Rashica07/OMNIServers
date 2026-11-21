import XCTest
@testable import craftpanel_Swift

/// Direct port of `analytics.rs`'s own `#[cfg(test)] mod tests`.
final class PlayerAnalyticsTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func writeServer(_ tag: String, latest: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-an-\(tag)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d.appending(path: "logs"), withIntermediateDirectories: true)
        try! latest.write(to: d.appending(path: "logs/latest.log"), atomically: true, encoding: .utf8)
        tempDirs.append(d)
        return d
    }

    func testCivilEpochMatchesKnownDates() {
        XCTAssertEqual(PlayerAnalytics.civilToDays(1970, 1, 1), 0)
        XCTAssertEqual(PlayerAnalytics.civilToDays(2000, 1, 1), 10_957)
        XCTAssertEqual(PlayerAnalytics.civilToDays(2001, 1, 1), 11_323)
    }

    func testParsesSessionsAndIP() {
        let log = """
        [10:00:00] [Server thread/INFO]: Steve[/1.2.3.4:5555] logged in with entity id 1 at (0,0,0)
        [10:00:01] [Server thread/INFO]: Steve joined the game
        [10:30:01] [Server thread/INFO]: Steve left the game
        [11:00:00] [Server thread/INFO]: Alex joined the game

        """
        let d = writeServer("basic", latest: log)
        let h = PlayerAnalytics.playerHistory(serverDir: d, serverOnline: false)
        let steve = h.first { $0.name == "Steve" }!
        XCTAssertEqual(steve.sessions, 1)
        XCTAssertEqual(steve.totalSecs, 1800)
        XCTAssertEqual(steve.lastIP, "1.2.3.4")
        // Alex never left; server offline -> session closed at join, 0s but counted
        let alex = h.first { $0.name == "Alex" }!
        XCTAssertEqual(alex.sessions, 1)
        // ordering: Alex (11:00) after Steve (10:30) -> Alex first
        XCTAssertEqual(h[0].name, "Alex")
    }

    func testReadsRotatedGzipAcrossTwoFiles() throws {
        let d = writeServer("rot", latest: "")
        func gz(_ body: String) throws -> Data {
            let tmp = FileManager.default.temporaryDirectory.appending(path: "cp-gz-src-\(UUID().uuidString).txt")
            try body.write(to: tmp, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tmp) }
            let out = FileManager.default.temporaryDirectory.appending(path: "cp-gz-out-\(UUID().uuidString).gz")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
            proc.arguments = ["-c", tmp.path]
            let pipe = Pipe()
            proc.standardOutput = pipe
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            try data.write(to: out)
            defer { try? FileManager.default.removeItem(at: out) }
            return try Data(contentsOf: out)
        }
        try gz("[08:00:00] [Server thread/INFO]: Bob joined the game\n")
            .write(to: d.appending(path: "logs/2026-08-29-1.log.gz"))
        try gz("[09:00:00] [Server thread/INFO]: Bob left the game\n")
            .write(to: d.appending(path: "logs/2026-08-29-2.log.gz"))

        let h = PlayerAnalytics.playerHistory(serverDir: d, serverOnline: false)
        let bob = try XCTUnwrap(h.first { $0.name == "Bob" })
        XCTAssertEqual(bob.sessions, 1)
        XCTAssertEqual(bob.totalSecs, 3600)
    }

    func testBucketizeCountsOverlappingIntervals() {
        // Alice [0,3600), Bob [1800,10800), Charlie [8100,9900) — plain
        // synthetic epoch seconds, no wall clock involved.
        let intervals: [(Int64, Int64)] = [(0, 3600), (1800, 10800), (8100, 9900)]
        let points = PlayerAnalytics.bucketize(intervals, since: 0, end: 10800, bucketSecs: 3600)
        XCTAssertEqual(points.count, 4, "buckets at 0, 3600, 7200, 10800")
        XCTAssertEqual(points[0].count, 2, "[0,3600): Alice + Bob overlap")
        XCTAssertEqual(points[1].count, 1, "[3600,7200): only Bob")
        XCTAssertEqual(points[2].count, 2, "[7200,10800): Bob + Charlie overlap")
        XCTAssertEqual(points[3].count, 0, "[10800,14400): Bob's leave at exactly 10800 doesn't count as still online")
    }

    func testConcurrentSeriesCountsOverlap() {
        func clock(_ secsAgo: Int64) -> String {
            let now = Int64(Date().timeIntervalSince1970)
            var s = (now - secsAgo) % 86400
            if s < 0 { s += 86400 }
            return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        }
        let log = """
        [\(clock(20))] [Server thread/INFO]: Alice joined the game
        [\(clock(15))] [Server thread/INFO]: Bob joined the game
        [\(clock(10))] [Server thread/INFO]: Alice left the game
        [\(clock(5))] [Server thread/INFO]: Bob left the game

        """
        let d = writeServer("concurrent", latest: log)
        let since = Int64(Date().timeIntervalSince1970) - 3600
        let points = PlayerAnalytics.concurrentSeries(serverDir: d, serverOnline: false, since: since, bucketSecsIn: 3600)
        XCTAssertFalse(points.isEmpty)
        XCTAssertTrue(points.contains { $0.count >= 2 }, "Alice + Bob's overlapping sessions should show up somewhere: \(points)")
    }

    func testConcurrentSeriesNeverReturnsAbsurdBucketCounts() {
        let d = writeServer("safety", latest: "")
        let points = PlayerAnalytics.concurrentSeries(serverDir: d, serverOnline: false, since: 0, bucketSecsIn: 1)
        XCTAssertLessThanOrEqual(points.count, 3001, "got \(points.count) buckets, safeguard should cap this")
    }

    func testIgnoresNonPlayerLines() {
        let log = "[10:00:00] [Server thread/INFO]: Preparing spawn area joined the game\n"
        let d = writeServer("noise", latest: log)
        let h = PlayerAnalytics.playerHistory(serverDir: d, serverOnline: false)
        XCTAssertTrue(h.allSatisfy { $0.name != "Preparing spawn area" })
    }
}
