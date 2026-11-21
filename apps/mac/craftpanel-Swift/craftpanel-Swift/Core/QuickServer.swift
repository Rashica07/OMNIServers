import Foundation

/// One click: the newest stable vanilla Minecraft, with memory sized for this Mac.
nonisolated struct QuickPlan: Equatable, Sendable {
    var mcVersion: String
    var ramMB: Int
    var name: String
    var dir: URL
}

nonisolated enum QuickServer {
    static let players = 5

    /// The newest release (Mojang lists newest first; snapshots are skipped).
    static func pickVersion(_ versions: [VersionInfo]) -> String? { versions.first { $0.kind == "release" }?.id }

    /// First free "My Server", "My Server 2"… with a folder that doesn't hold anything yet.
    static func pickName(baseDir: URL, usedNames: [String]) -> (name: String, dir: URL) {
        let used = Set(usedNames.map { $0.lowercased() })
        var i = 1
        while true {
            let name = i == 1 ? "My Server" : "My Server \(i)"
            let dir = baseDir.appending(path: name.replacingOccurrences(of: " ", with: "-"))
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            if !used.contains(name.lowercased()) && contents.isEmpty { return (name, dir) }
            i += 1
        }
    }

    static func plan(versions: [VersionInfo], system: SystemMemory, baseDir: URL, usedNames: [String]) -> QuickPlan? {
        guard let mc = pickVersion(versions) else { return nil }
        let (name, dir) = pickName(baseDir: baseDir, usedNames: usedNames)
        return QuickPlan(mcVersion: mc, ramMB: RamAdvisor.recommend(kind: .vanillaLike, players: players, safeMaxMB: system.safeMaxMB), name: name, dir: dir)
    }

    @MainActor
    static func create(existing: [ServerRecord], baseDir: URL, progress: @escaping (ProvisionProgress) -> Void) async throws -> ServerRecord {
        progress(ProvisionProgress(stage: "fetch", message: "Finding the latest Minecraft…", pct: nil))
        let versions = try await Provisioner.listVersions(.vanilla)
        guard let p = plan(versions: versions, system: SystemMemory.current(), baseDir: baseDir, usedNames: existing.map(\.name)) else {
            throw ProvisionError.message("Couldn't find a Minecraft release to install.")
        }
        let spec = CreateSpec(loader: .vanilla, mcVersion: p.mcVersion, loaderVersion: nil, dir: p.dir, name: p.name,
                              ramMB: UInt32(p.ramMB), javaPath: AppDefaults.defaultJavaPath)
        let created = try await Provisioner.create(spec, progress: progress)
        let taken = Set(existing.map { NetworkInfo.port(serverDir: URL(fileURLWithPath: $0.path)) })
        Provisioner.applyStartingSettings(dir: p.dir, bedrock: false, port: Provisioner.pickFreePort(taken: taken),
                                          seed: nil, gamemode: nil, difficulty: nil, motd: nil, maxPlayers: nil)
        Attribution.stamp(serverDir: p.dir, origin: "created")
        return ServerRecord(name: p.name, path: p.dir.path, serverType: created.serverType, launchTarget: created.launchTarget,
                            mcVersion: created.mcVersion, javaPath: created.javaPath, ramMB: UInt32(p.ramMB))
    }
}
