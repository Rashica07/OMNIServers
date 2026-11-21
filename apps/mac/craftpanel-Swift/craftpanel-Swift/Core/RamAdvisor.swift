import Foundation
import Darwin

/// This Mac's memory facts plus the RAM recommendation for a server —
/// Tauri's `system.rs` (total / available / safe max) extended with the
/// memory type, the chip, and a per-kind, per-player recommendation.
nonisolated struct SystemMemory: Sendable, Equatable {
    var totalMB: Int
    var availableMB: Int
    /// "LPDDR5", "DDR4"… — nil until the (async) hardware query returns.
    var memoryType: String?
    var chip: String
    var cores: Int

    /// The most this Mac can spare without starving macOS: 75% of total,
    /// and at least 2 GB left over. Same rule as Tauri, with a bigger
    /// floor for macOS itself.
    var safeMaxMB: Int { max(1024, min(totalMB * 3 / 4, totalMB - 2048)) }

    /// Under 8 GB total or 4 cores, a server plus macOS is tight.
    var isWeak: Bool { totalMB < 8 * 1024 || cores < 4 }

    static func current() -> SystemMemory {
        SystemMemory(totalMB: Int(ProcessInfo.processInfo.physicalMemory / 1_048_576),
                     availableMB: availableMB(), memoryType: nil, chip: chipName(),
                     cores: ProcessInfo.processInfo.activeProcessorCount)
    }

    /// Adds the memory type from `system_profiler` (~0.2 s, so off-main).
    static func detailed() async -> SystemMemory {
        var m = current()
        m.memoryType = await Task.detached { memoryType() }.value
        return m
    }

    /// Free + inactive + purgeable + speculative pages — close to what
    /// Activity Monitor would let a new process have without swapping.
    static func availableMB() -> Int {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        let pages = UInt64(stats.free_count) + UInt64(stats.inactive_count) + UInt64(stats.purgeable_count) + UInt64(stats.speculative_count)
        return Int(pages * UInt64(vm_kernel_page_size) / 1_048_576)
    }

    static func chipName() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// Apple Silicon reports one top-level `dimm_type`; Intel Macs list
    /// each slot under `_items`.
    static func memoryType() -> String? {
        guard let r = try? Subprocess.run("/usr/sbin/system_profiler", ["SPMemoryDataType", "-json"], timeout: 5),
              let obj = try? JSONSerialization.jsonObject(with: r.stdout) as? [String: Any],
              let entries = obj["SPMemoryDataType"] as? [[String: Any]], let first = entries.first else { return nil }
        return parseType(first)
    }

    static func parseType(_ entry: [String: Any]) -> String? {
        if let t = entry["dimm_type"] as? String, !t.isEmpty, t != "empty" { return t }
        for slot in (entry["_items"] as? [[String: Any]]) ?? [] {
            guard let t = slot["dimm_type"] as? String, !t.isEmpty, t != "empty" else { continue }
            if let speed = slot["dimm_speed"] as? String, !speed.isEmpty { return "\(t) \(speed)" }
            return t
        }
        return nil
    }
}

nonisolated enum SystemRAM {
    static var totalMB: Int { Int(ProcessInfo.processInfo.physicalMemory / 1_048_576) }
    static func format(mb: Int) -> String {
        mb % 1024 == 0 ? "\(mb / 1024) GB" : String(format: "%.1f GB", Double(mb) / 1024)
    }
}

nonisolated enum RamAdvisor {
    /// What kind of server the memory is for — drives the base and the
    /// per-player cost.
    enum Kind: Sendable, Equatable {
        case vanillaLike      // Vanilla, Paper, Fabric, Quilt…
        case minigame         // Skyblock, Bedwars: small maps, few loaded chunks
        case modded           // Forge / NeoForge with an unknown mod list
        case modpack          // a whole pack
        case bedrock          // native binary; the slider doesn't apply

        init(serverType: ServerType) {
            if serverType.isBedrock || serverType.isOmniHost { self = .bedrock } else if serverType.isForgeFamily { self = .modded } else { self = .vanillaLike }
        }

        var label: String {
            switch self {
            case .vanillaLike: "a vanilla-style server"
            case .minigame: "this game mode"
            case .modded: "a modded server"
            case .modpack: "a modpack"
            case .bedrock: "Bedrock"
            }
        }
    }

    static let minMB = 1024

    /// Recommended heap, rounded up to 512 MB, never above the safe limit.
    static func recommend(kind: Kind, players: Int, safeMaxMB: Int) -> Int {
        let p = max(1, players)
        let (base, perPlayer): (Int, Int) = switch kind {
        case .vanillaLike: (2048, 128)
        case .minigame: (2048, 96)
        case .modded: (4096, 192)
        case .modpack: (4096, 256)
        case .bedrock: (1024, 0)
        }
        let raw = base + perPlayer * p
        let rounded = (raw + 511) / 512 * 512
        return max(minMB, min(rounded, max(minMB, safeMaxMB)))
    }

    /// What the server would ideally get, ignoring this Mac's limit —
    /// used to say "this Mac is short on memory for this".
    static func ideal(kind: Kind, players: Int) -> Int {
        recommend(kind: kind, players: players, safeMaxMB: .max)
    }

    struct Warning: Sendable, Equatable, Identifiable {
        enum Level: Sendable { case caution, serious }
        let level: Level
        let message: String
        var id: String { message }
    }

    /// Everything worth warning about before creating/starting with
    /// `chosenMB`. `otherAllocatedMB` is what already-running servers hold.
    static func warnings(chosenMB: Int, kind: Kind, players: Int, system: SystemMemory, otherAllocatedMB: Int = 0) -> [Warning] {
        guard kind != .bedrock else { return [] }
        var out: [Warning] = []
        let ideal = ideal(kind: kind, players: players)
        let gb = { (mb: Int) in SystemRAM.format(mb: mb) }
        if chosenMB > system.safeMaxMB {
            out.append(.init(level: .serious, message: "\(gb(chosenMB)) is over this Mac's \(gb(system.safeMaxMB)) safe limit — macOS may start swapping and everything slows down."))
        } else if otherAllocatedMB > 0, chosenMB + otherAllocatedMB > system.safeMaxMB {
            out.append(.init(level: .serious, message: "Together with the servers already running (\(gb(otherAllocatedMB))), this goes over the \(gb(system.safeMaxMB)) safe limit."))
        }
        if ideal > system.safeMaxMB {
            out.append(.init(level: .caution, message: "\(kind.label.prefix(1).uppercased() + kind.label.dropFirst()) with \(players) player\(players == 1 ? "" : "s") ideally wants \(gb(ideal)); this Mac can only spare \(gb(system.safeMaxMB)). Expect lag with a full server."))
        }
        if chosenMB < ideal * 3 / 4 {
            out.append(.init(level: .caution, message: "\(gb(chosenMB)) is low for \(kind.label) with \(players) player\(players == 1 ? "" : "s") (recommended \(gb(min(ideal, system.safeMaxMB)))). It may lag or crash with “OutOfMemoryError”."))
        }
        if system.isWeak {
            out.append(.init(level: .caution, message: "This Mac has \(gb(system.totalMB)) of memory and \(system.cores) cores — running a server alongside everyday apps may be sluggish. Keep player counts small and close heavy apps."))
        }
        return out
    }
}
