import Foundation

/// Live health: the JVM's RAM + CPU, and TPS/MSPT pulled over RCON.
/// Direct port of `perf.rs`.
///
/// TPS isn't in vanilla RCON, so this tries a sequence of commands and
/// parses whichever the server understands: `/tick query` (vanilla
/// 1.21+), `/tps` (Paper/Purpur/Spigot), `/spark tps`.
nonisolated struct PerfSample: Sendable, Equatable {
    /// resident memory of the server process, MB
    var ramMB: UInt32?
    /// CPU usage of the process, percent (can exceed 100 on multi-core)
    var cpuPct: Double?
    /// ticks per second (20 is perfect)
    var tps: Double?
    /// milliseconds per tick (< 50 is healthy)
    var mspt: Double?
    /// where tps/mspt came from, for the UI
    var source: String?
}

nonisolated enum PerfSampler {
    static func sample(record: ServerRecord, pid: Int32?, isRunning: Bool) async -> PerfSample {
        var s = PerfSample()
        if let pid {
            let (ram, cpu) = processSample(pid: pid)
            s.ramMB = ram
            s.cpuPct = cpu
        }
        if isRunning {
            let (tps, mspt, source) = await tpsOverRCON(record: record)
            s.tps = tps
            s.mspt = mspt
            s.source = source
        }
        return s
    }

    /// RSS and CPU% via `proc_pidinfo(PROC_PIDTASKINFO)` — no `ps`
    /// subprocess (this runs every minute per server on the main actor).
    /// CPU% is the delta of user+system time since the previous sample for
    /// that pid (like Activity Monitor), 100% = one full core. The first
    /// sample for a pid falls back to the lifetime average.
    static func processSample(pid: Int32) -> (ramMB: UInt32?, cpuPct: Double?) {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return (nil, nil) }
        let ramMB = UInt32(info.pti_resident_size / 1_048_576)
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        // pti_total_* are Mach absolute-time units (not ns on Apple Silicon).
        let cpuNs = Double(info.pti_total_user + info.pti_total_system) * Double(tb.numer) / Double(tb.denom)
        let now = DispatchTime.now().uptimeNanoseconds
        let prev = cpuHistory.swap(pid: pid, sample: (cpuNs, now))
        let cpu: Double?
        if let prev, now > prev.at {
            cpu = max(0, (cpuNs - prev.cpuNs) / Double(now - prev.at) * 100)
        } else if let start = ServerSession.startTime(pid) {
            let wall = max(1, Date().timeIntervalSince1970 - Double(start))
            cpu = cpuNs / 1e9 / wall * 100
        } else {
            cpu = nil
        }
        return (ramMB, cpu)
    }

    private static let cpuHistory = CPUHistory()

    private final class CPUHistory: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [Int32: (cpuNs: Double, at: UInt64)] = [:]
        func swap(pid: Int32, sample: (cpuNs: Double, at: UInt64)) -> (cpuNs: Double, at: UInt64)? {
            lock.lock(); defer { lock.unlock() }
            let old = map[pid]
            map[pid] = sample
            if map.count > 256 { map = [pid: sample] }
            return old
        }
    }

    static func tpsOverRCON(record: ServerRecord) async -> (tps: Double?, mspt: Double?, source: String?) {
        // vanilla 1.21+: "Target tick rate: 20.0 per second.\nAverage time per tick: 1.2ms ..."
        if let out = try? await RconService.shared.run(record: record, command: "tick query") {
            let l = out.lowercased()
            if l.contains("tick rate") || l.contains("per tick") {
                let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
                let mspt = lines.first { $0.lowercased().contains("per tick") }.flatMap { numAfterColon(String($0)) }
                let tps = lines.first { $0.lowercased().contains("tick rate") }.flatMap { numAfterColon(String($0)) }
                    ?? mspt.map { min(1000.0 / $0, 20.0) }
                if tps != nil || mspt != nil {
                    return (tps, mspt, "vanilla /tick")
                }
            }
        }
        // Paper / Purpur / Spigot: "TPS from last 1m, 5m, 15m: *20.0, 20.0, 20.0"
        if let out = try? await RconService.shared.run(record: record, command: "tps"), out.lowercased().contains("tps") {
            let tps = numAfterColon(stripColor(out))
            let msptOut = try? await RconService.shared.run(record: record, command: "mspt")
            let mspt = msptOut.flatMap { numAfterColon(stripColor($0)) ?? firstNum(stripColor($0)) }
            if tps != nil {
                return (tps, mspt, "/tps")
            }
        }
        // spark: "TPS from last 5s, 10s, 1m, 5m, 15m:  20, 20, 20, 20, 20"
        if let out = try? await RconService.shared.run(record: record, command: "spark tps"), out.lowercased().contains("tps") {
            let tps = numAfterColon(stripColor(out))
            if tps != nil {
                return (tps, nil, "spark")
            }
        }
        return (nil, nil, nil)
    }

    /// First run of digits/./- in the string parsed as a Double ("2.5ms" -> 2.5).
    static func firstNum(_ s: String) -> Double? {
        var tok = ""
        for c in s {
            if c.isASCII, c.isNumber || c == "." || (c == "-" && tok.isEmpty) {
                tok.append(c)
            } else if !tok.isEmpty {
                break
            }
        }
        while tok.hasSuffix(".") { tok.removeLast() }
        return Double(tok)
    }

    /// Number after the first ':' -- for "TPS ... 1m, 5m, 15m: 19.98, 20, 20"
    static func numAfterColon(_ s: String) -> Double? {
        guard let idx = s.firstIndex(of: ":") else { return nil }
        return firstNum(String(s[s.index(after: idx)...]))
    }

    /// Minecraft section-sign colour codes.
    static func stripColor(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            if c == "\u{a7}" {
                _ = it.next()
            } else {
                out.append(c)
            }
        }
        return out
    }
}
