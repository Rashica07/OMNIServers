import Foundation

/// Player history from the server logs — first/last seen, session count,
/// total playtime, last IP, plus a bucketed concurrent-player-count
/// series for a "peak hours" chart. Direct port of `analytics.rs`.
/// Offline-mode safe: everything is keyed on the name. Parses
/// `logs/latest.log` plus rotated `logs/YYYY-MM-DD-N.log[.gz]` — line
/// timestamps are only `HH:MM:SS`, so the date comes from the filename
/// (or `latest.log`'s own mtime), rolling forward when the clock wraps
/// midnight within one file.
nonisolated struct PlayerStat: Sendable, Identifiable {
    var id: String { name }
    var name: String
    var firstSeen: Int64
    var lastSeen: Int64
    var sessions: UInt32
    var totalSecs: Int64
    var lastIP: String?
    var online: Bool
}

nonisolated struct ConcurrentPoint: Sendable {
    /// bucket start, unix epoch
    var ts: Int64
    var count: UInt32
}

nonisolated enum PlayerAnalytics {
    private static func now() -> Int64 { Int64(Date().timeIntervalSince1970) }

    /// Days since the Unix epoch for a civil date (Howard Hinnant's algorithm).
    static func civilToDays(_ y0: Int64, _ m: Int64, _ d: Int64) -> Int64 {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private struct LogSrc {
        /// sort key (older first)
        var order: (Int64, Int64)
        var baseEpoch: Int64
        var gz: Bool
        var path: URL
    }

    private static func collectSources(_ logsDir: URL) -> [LogSrc] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: logsDir.path) else { return [] }
        var out: [LogSrc] = []
        for name in names {
            let path = logsDir.appendingPathComponent(name)
            if name == "latest.log" {
                let base: Int64
                if let attrs = try? fm.attributesOfItem(atPath: path.path), let modified = attrs[.modificationDate] as? Date {
                    base = (Int64(modified.timeIntervalSince1970) / 86400) * 86400
                } else {
                    base = (now() / 86400) * 86400
                }
                out.append(LogSrc(order: (Int64.max, 0), baseEpoch: base, gz: false, path: path))
                continue
            }
            // YYYY-MM-DD-N.log or .log.gz
            var stem = name
            if stem.hasSuffix(".gz") { stem.removeLast(3) }
            if stem.hasSuffix(".log") { stem.removeLast(4) }
            let parts = stem.split(separator: "-")
            if parts.count == 4, let y = Int64(parts[0]), let mo = Int64(parts[1]), let d = Int64(parts[2]), let n = Int64(parts[3]) {
                let base = civilToDays(y, mo, d) * 86400
                out.append(LogSrc(order: (base, n), baseEpoch: base, gz: name.hasSuffix(".gz"), path: path))
            }
        }
        out.sort { $0.order.0 != $1.order.0 ? $0.order.0 < $1.order.0 : $0.order.1 < $1.order.1 }
        return out
    }

    private static func readText(_ src: LogSrc) -> String? {
        guard let data = try? Data(contentsOf: src.path) else { return nil }
        if src.gz {
            return gunzip(data)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Native gzip (was a `gunzip` subprocess that deadlocked on any
    /// rotated log over ~64 KB: all of stdin was written before stdout was read).
    private static func gunzip(_ data: Data) -> String? {
        Gzip.decompress(data).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func isValidName(_ n: Substring) -> Bool {
        !n.isEmpty && n.count <= 16 && n.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    /// "[HH:MM:SS] ..." -> seconds since midnight.
    private static func hms(_ line: String) -> Int64? {
        let chars = Array(line)
        guard chars.count >= 10, chars[0] == "[", chars[9] == "]" else { return nil }
        guard let h = Int64(String(chars[1...2])), let m = Int64(String(chars[4...5])), let s = Int64(String(chars[7...8])) else { return nil }
        return h * 3600 + m * 60 + s
    }

    private struct Acc {
        var first: Int64 = 0
        var last: Int64 = 0
        var sessions: UInt32 = 0
        var total: Int64 = 0
        var ip: String?
    }

    static func playerHistory(serverDir: URL, serverOnline: Bool) -> [PlayerStat] {
        let logsDir = serverDir.appendingPathComponent("logs")
        var stats: [String: Acc] = [:]
        var open: [String: Int64] = [:] // name -> join epoch
        var pendingIP: [String: String] = [:]

        for src in collectSources(logsDir) {
            guard let text = readText(src) else { continue }
            var day: Int64 = 0
            var prevSecs: Int64 = -1

            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let lineStr = String(line)
                guard let secs = hms(lineStr) else { continue }
                if prevSecs >= 0, secs + 3600 < prevSecs { day += 1 }
                prevSecs = secs
                let ts = src.baseEpoch + day * 86400 + secs

                guard let range = lineStr.range(of: "]: ") else { continue }
                let rest = lineStr[range.upperBound...]

                if rest.hasSuffix(" joined the game") {
                    let name = rest.dropLast(" joined the game".count)
                    guard isValidName(name) else { continue }
                    let nameStr = String(name)
                    open[nameStr] = ts
                    var a = stats[nameStr] ?? Acc()
                    if a.first == 0 { a.first = ts }
                    a.last = max(a.last, ts)
                    if let ip = pendingIP.removeValue(forKey: nameStr) { a.ip = ip }
                    stats[nameStr] = a
                } else if rest.hasSuffix(" left the game") {
                    let name = rest.dropLast(" left the game".count)
                    guard isValidName(name) else { continue }
                    let nameStr = String(name)
                    var a = stats[nameStr] ?? Acc()
                    if let joined = open.removeValue(forKey: nameStr) {
                        a.total += max(ts - joined, 0)
                        a.sessions += 1
                    }
                    a.last = max(a.last, ts)
                    if a.first == 0 { a.first = ts }
                    stats[nameStr] = a
                } else if let idx = rest.range(of: "[/") {
                    // "<name>[/1.2.3.4:5678] logged in with ..."
                    guard rest.contains(" logged in with ") else { continue }
                    let name = rest[rest.startIndex..<idx.lowerBound]
                    guard isValidName(name) else { continue }
                    let afterBracket = rest[idx.upperBound...]
                    if let end = afterBracket.firstIndex(of: "]") {
                        let addr = afterBracket[afterBracket.startIndex..<end]
                        let ip = addr.split(separator: ":").first.map(String.init) ?? String(addr)
                        pendingIP[String(name)] = ip
                    }
                }
            }
        }

        // sessions still open at the end of the logs
        let stillOpen = Set(open.keys)
        for (name, joined) in open {
            var a = stats[name] ?? Acc()
            let end = serverOnline ? now() : max(a.last, joined)
            a.total += max(end - joined, 0)
            a.sessions += 1
            a.last = max(a.last, end)
            stats[name] = a
        }

        var out = stats.map { name, a in
            PlayerStat(name: name, firstSeen: a.first, lastSeen: a.last, sessions: a.sessions,
                       totalSecs: a.total, lastIP: a.ip, online: serverOnline && stillOpen.contains(name))
        }
        out.sort { $0.lastSeen > $1.lastSeen }
        return out
    }

    /// Bucketed concurrent-player counts from `since` to now. Reuses the
    /// exact same log sources and join/leave parsing as `playerHistory`.
    static func concurrentSeries(serverDir: URL, serverOnline: Bool, since: Int64, bucketSecsIn: Int64) -> [ConcurrentPoint] {
        guard bucketSecsIn > 0 else { return [] }
        let end = now()
        // Coarsen automatically rather than trust the caller's bucket
        // size — `since = 0` with a small bucket would otherwise mean
        // iterating millions of empty buckets between the epoch and now.
        let span = max(end - since, bucketSecsIn)
        let maxBuckets: Int64 = 3000
        let bucketSecs = span / bucketSecsIn > maxBuckets ? span / maxBuckets + 1 : bucketSecsIn

        let logsDir = serverDir.appendingPathComponent("logs")
        var open: [String: Int64] = [:]
        var intervals: [(Int64, Int64)] = []
        var lastLineTS: Int64 = 0

        for src in collectSources(logsDir) {
            guard let text = readText(src) else { continue }
            var day: Int64 = 0
            var prevSecs: Int64 = -1
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let lineStr = String(line)
                guard let secs = hms(lineStr) else { continue }
                if prevSecs >= 0, secs + 3600 < prevSecs { day += 1 }
                prevSecs = secs
                let ts = src.baseEpoch + day * 86400 + secs
                lastLineTS = max(lastLineTS, ts)
                guard let range = lineStr.range(of: "]: ") else { continue }
                let rest = lineStr[range.upperBound...]
                if rest.hasSuffix(" joined the game") {
                    let name = String(rest.dropLast(" joined the game".count))
                    if isValidName(Substring(name)) { open[name] = ts }
                } else if rest.hasSuffix(" left the game") {
                    let name = String(rest.dropLast(" left the game".count))
                    if isValidName(Substring(name)), let joined = open.removeValue(forKey: name) {
                        intervals.append((joined, ts))
                    }
                }
            }
        }
        let tail = serverOnline ? end : lastLineTS
        for (_, joined) in open {
            intervals.append((joined, max(tail, joined)))
        }

        return bucketize(intervals, since: since, end: end, bucketSecs: bucketSecs)
    }

    /// The pure part of `concurrentSeries`: how many `[join, leave)`
    /// intervals overlap each bucket from `since` (rounded down to a
    /// bucket boundary) to `end`.
    static func bucketize(_ intervals: [(Int64, Int64)], since: Int64, end: Int64, bucketSecs: Int64) -> [ConcurrentPoint] {
        let start = (since / bucketSecs) * bucketSecs
        var out: [ConcurrentPoint] = []
        var t = start
        while t <= end {
            let bucketEnd = t + bucketSecs
            let count = intervals.count { $0.0 < bucketEnd && $0.1 > t }
            out.append(ConcurrentPoint(ts: t, count: UInt32(count)))
            t = bucketEnd
        }
        return out
    }
}
