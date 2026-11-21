import Foundation

/// World management. Vanilla loads one overworld (`level-name`) plus its
/// `<name>_nether` / `<name>_the_end` siblings; other saved worlds sit in
/// the folder unused until switched to. Direct port of `worlds.rs`.
///
/// Switch / rename / delete require the server to be stopped (checked by
/// the UI layer, same as the Tauri app's command layer). Deletes move to
/// `.craftpanel-trash/`, never erase.
nonisolated struct World: Sendable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    var active: Bool
    var sizeBytes: UInt64
    var seed: String?
    var hasNether: Bool
    var hasEnd: Bool
}

nonisolated struct WorldInfo: Sendable {
    var active: String
    var worlds: [World]
}

nonisolated enum WorldManager {
    private static let trash = ".craftpanel-trash"

    private static func dirSize(_ p: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(at: p, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return 0
        }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += UInt64(values.fileSize ?? 0)
        }
        return total
    }

    private static func isWorldDir(_ p: URL) -> Bool {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        guard fm.fileExists(atPath: p.path, isDirectory: &isDir), isDir.boolValue else { return false }
        return fm.fileExists(atPath: p.appending(path: "level.dat").path)
            || fm.fileExists(atPath: p.appending(path: "level.dat_old").path)
    }

    // level.dat is NBT/gzip -- not worth a parser here, matches the Rust
    // source's own "always nil" placeholder.
    private static func readSeed(_ dir: URL) -> String? { nil }

    static func list(serverDir: URL) -> WorldInfo {
        let props = Properties.load(dir: serverDir)
        let active = props.getOr("level-name", "world")
        let seedProp = props.get("level-seed").flatMap { $0.isEmpty ? nil : $0 }

        var worlds: [World] = []
        if let entries = try? FileManager.default.contentsOfDirectory(at: serverDir, includingPropertiesForKeys: nil) {
            for e in entries {
                let name = e.lastPathComponent
                if name.hasPrefix(".") || name.hasSuffix("_nether") || name.hasSuffix("_the_end") { continue }
                guard isWorldDir(e) else { continue }
                let isActive = name == active
                let netherDir = serverDir.appending(path: "\(name)_nether")
                let endDir = serverDir.appending(path: "\(name)_the_end")
                worlds.append(World(
                    name: name, active: isActive,
                    sizeBytes: dirSize(e) + dirSize(netherDir) + dirSize(endDir),
                    seed: isActive ? seedProp : readSeed(e),
                    hasNether: (try? netherDir.checkResourceIsReachable()) ?? false,
                    hasEnd: (try? endDir.checkResourceIsReachable()) ?? false
                ))
            }
        }
        // the active world may not exist on disk yet (fresh "create world")
        if !worlds.contains(where: \.active) {
            worlds.append(World(name: active, active: true, sizeBytes: 0, seed: seedProp, hasNether: false, hasEnd: false))
        }
        worlds.sort { a, b in
            if a.active != b.active { return a.active }
            return a.name.lowercased() < b.name.lowercased()
        }
        return WorldInfo(active: active, worlds: worlds)
    }

    private static func safeName(_ name: String) throws -> String {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != ".", n != "..",
              !n.contains("/"), !n.contains("\\"), !n.contains(":"),
              !n.hasPrefix(".") else {
            throw RconServiceError.message("That world name isn't allowed.")
        }
        return n
    }

    /// Point `level-name` at `name` (line-preserving). The server
    /// generates it on next start if it doesn't exist yet.
    static func setActive(serverDir: URL, name: String) throws {
        let name = try safeName(name)
        var props = Properties.load(dir: serverDir)
        guard props.existed else {
            throw RconServiceError.message("No server.properties yet — start the server once first.")
        }
        props.set("level-name", name)
        try props.save()
    }

    /// Set a fresh world name (+ optional seed) so the next start generates it.
    static func create(serverDir: URL, name: String, seed: String?) throws {
        let name = try safeName(name)
        guard !FileManager.default.fileExists(atPath: serverDir.appending(path: name).path) else {
            throw RconServiceError.message("A world folder with that name already exists — switch to it instead.")
        }
        var props = Properties.load(dir: serverDir)
        props.set("level-name", name)
        let trimmedSeed = seed?.trimmingCharacters(in: .whitespaces)
        props.set("level-seed", (trimmedSeed?.isEmpty == false) ? trimmedSeed! : "")
        try props.save()
    }

    static func rename(serverDir: URL, from: String, to: String) throws {
        let from = try safeName(from)
        let to = try safeName(to)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: serverDir.appending(path: from).path, isDirectory: &isDir), isDir.boolValue else {
            throw RconServiceError.message("That world folder doesn't exist.")
        }
        guard !fm.fileExists(atPath: serverDir.appending(path: to).path) else {
            throw RconServiceError.message("A world with the new name already exists.")
        }
        for suffix in ["", "_nether", "_the_end"] {
            let src = serverDir.appending(path: "\(from)\(suffix)")
            var srcIsDir: ObjCBool = false
            if fm.fileExists(atPath: src.path, isDirectory: &srcIsDir), srcIsDir.boolValue {
                try fm.moveItem(at: src, to: serverDir.appending(path: "\(to)\(suffix)"))
            }
        }
        // keep it active if it was
        var props = Properties.load(dir: serverDir)
        if props.getOr("level-name", "world") == from {
            props.set("level-name", to)
            try props.save()
        }
    }

    static func delete(serverDir: URL, name: String) throws {
        let name = try safeName(name)
        guard Properties.load(dir: serverDir).getOr("level-name", "world") != name else {
            throw RconServiceError.message("That's the active world — switch to another one first.")
        }
        let trashDir = serverDir.appending(path: trash)
        let fm = FileManager.default
        try fm.createDirectory(at: trashDir, withIntermediateDirectories: true)
        var moved = 0
        let ts = Int64(Date().timeIntervalSince1970)
        for suffix in ["", "_nether", "_the_end"] {
            let src = serverDir.appending(path: "\(name)\(suffix)")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue {
                try fm.moveItem(at: src, to: trashDir.appending(path: "\(ts)-\(name)\(suffix)"))
                moved += 1
            }
        }
        guard moved > 0 else {
            throw RconServiceError.message("That world folder doesn't exist.")
        }
    }

    /// Import a world folder or .zip by copying it into this server. The original
    /// is never moved, unsafe zip paths and symlinks are rejected, and optional
    /// activation is applied only after the copy is complete.
    @discardableResult
    static func importWorld(from source: URL, serverDir: URL, name requestedName: String? = nil,
                            activate: Bool = false, serverRunning: Bool = false) throws -> String {
        if activate && serverRunning { throw RconServiceError.message("Stop the server before making an imported world active.") }
        let fm = FileManager.default
        let folder = source.hasDirectoryPath || (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let sourceRoot = folder ? try findWorldRoot(source) : nil
        if folder && sourceRoot == nil { throw RconServiceError.message("That folder does not contain a Minecraft world (level.dat).") }
        let zipEntries: [String] = folder ? [] : try zipEntries(source)
        let levelEntry = zipEntries.first { $0.lowercased() == "level.dat" || $0.lowercased().hasSuffix("/level.dat") }
        if !folder && levelEntry == nil { throw RconServiceError.message("That .zip does not contain a Minecraft world (level.dat).") }
        if let unsafe = zipEntries.first(where: { BackupManager.isUnsafeEntry($0) }) {
            throw RconServiceError.message("The archive contains an unsafe path: \(unsafe)")
        }
        let basePrefix = levelEntry.map { String($0.dropLast("level.dat".count)) } ?? ""
        let archiveWorldName = basePrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")).split(separator: "/").last.map(String.init)
        let originalName = sourceRoot?.lastPathComponent ?? archiveWorldName ?? source.deletingPathExtension().lastPathComponent
        let requested = try safeName(requestedName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? requestedName! : originalName)
        var name = requested
        var suffix = 2
        while fm.fileExists(atPath: serverDir.appending(path: name).path) {
            name = "\(requested) (\(suffix))"; suffix += 1
        }
        let stage = fm.temporaryDirectory.appending(path: "cp-world-import-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stage) }
        let stageWorld = stage.appending(path: name)
        try fm.createDirectory(at: stageWorld, withIntermediateDirectories: true)

        if let sourceRoot {
            try copyTreeWithoutLinks(from: sourceRoot, to: stageWorld)
            for dimension in ["_nether", "_the_end"] {
                let sibling = sourceRoot.deletingLastPathComponent().appending(path: sourceRoot.lastPathComponent + dimension)
                if isWorldDir(sibling) { try copyTreeWithoutLinks(from: sibling, to: stage.appending(path: name + dimension)) }
            }
        } else {
            for entry in zipEntries {
                guard !entry.hasSuffix("/"), !BackupManager.isUnsafeEntry(entry) else { continue }
                let lower = entry.lowercased()
                let dimensionPrefix = basePrefix.isEmpty ? "" : String(basePrefix.dropLast())
                let dimension: String? = ["_nether", "_the_end"].first { entry.hasPrefix(dimensionPrefix + $0 + "/") }
                let relative: String
                let destinationRoot: URL
                if let dimension {
                    relative = String(entry.dropFirst((dimensionPrefix + dimension + "/").count))
                    destinationRoot = stage.appending(path: name + dimension)
                } else if entry.hasPrefix(basePrefix) {
                    relative = String(entry.dropFirst(basePrefix.count)); destinationRoot = stageWorld
                } else { continue }
                guard !relative.isEmpty, !BackupManager.isUnsafeEntry(relative), !lower.contains("\0") else { continue }
                let parts = relative.split(separator: "/").map(String.init)
                guard !parts.isEmpty else { continue }
                var target = destinationRoot
                for part in parts.dropLast() { target.append(path: part) }
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                let extracted = try Subprocess.run("/usr/bin/unzip", ["-p", source.path, entry], timeout: 120)
                guard extracted.status == 0 else { throw RconServiceError.message("Could not read \(entry) from the world archive.") }
                try extracted.stdout.write(to: target.appending(path: parts.last!), options: .atomic)
            }
        }
        guard isWorldDir(stageWorld) else { throw RconServiceError.message("The imported archive did not contain a usable level.dat.") }
        try fm.moveItem(at: stageWorld, to: serverDir.appending(path: name))
        for dimension in ["_nether", "_the_end"] {
            let staged = stage.appending(path: name + dimension)
            if fm.fileExists(atPath: staged.path) { try fm.moveItem(at: staged, to: serverDir.appending(path: name + dimension)) }
        }
        if activate { try setActive(serverDir: serverDir, name: name) }
        return name
    }

    static func exportWorld(serverDir: URL, name: String, to destination: URL) throws {
        let name = try safeName(name)
        guard isWorldDir(serverDir.appending(path: name)) else { throw RconServiceError.message("That world folder does not exist.") }
        var items = [name]
        for suffix in ["_nether", "_the_end"] where isWorldDir(serverDir.appending(path: name + suffix)) { items.append(name + suffix) }
        let result = try Subprocess.run("/usr/bin/zip", ["-q", "-r", destination.path] + items, cwd: serverDir, timeout: 600)
        guard result.status == 0 else { throw RconServiceError.message("Could not export the world: \(result.stderrString)") }
    }

    private static func zipEntries(_ zip: URL) throws -> [String] {
        let result = try Subprocess.run("/usr/bin/zipinfo", ["-1", zip.path], timeout: 120)
        guard result.status == 0 else { throw RconServiceError.message("Choose a valid .zip archive.") }
        let entries = result.stdoutString.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard entries.count <= 200_000 else { throw RconServiceError.message("That archive contains too many files to import safely.") }
        return entries
    }

    private static func findWorldRoot(_ root: URL) throws -> URL? {
        if isWorldDir(root) { return root }
        let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        for child in children {
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true && values?.isSymbolicLink != true && isWorldDir(child) { return child }
        }
        return nil
    }

    private static func copyTreeWithoutLinks(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { enumerator.skipDescendants(); continue }
            let relative = String(item.path.dropFirst(source.path.count + 1))
            guard !BackupManager.isUnsafeEntry(relative) else { throw RconServiceError.message("That world contains an unsafe path.") }
            let target = destination.appending(path: relative)
            if values.isDirectory == true { try fm.createDirectory(at: target, withIntermediateDirectories: true) }
            else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: item, to: target)
            }
        }
    }

    static func versionName(in levelDat: URL) -> String? {
        guard let (_, root, _) = try? NBT.read(levelDat) else { return nil }
        func find(_ node: NBTNode) -> String? {
            guard case .compound(let fields) = node else { return nil }
            if let data = fields.first(where: { $0.0 == "Data" })?.1,
               case .compound(let dataFields) = data,
               let version = dataFields.first(where: { $0.0 == "Version" })?.1,
               case .compound(let versionFields) = version,
               case .string(let name)? = versionFields.first(where: { $0.0 == "Name" })?.1 { return name }
            for (_, child) in fields { if let found = find(child) { return found } }
            return nil
        }
        return find(root)
    }

    /// Standard Java Edition save location. Returned entries must contain a
    /// level.dat and are sorted by their human-readable folder name.
    static func singlePlayerWorlds(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let saves = home.appending(path: "Library/Application Support/minecraft/saves")
        return ((try? FileManager.default.contentsOfDirectory(at: saves, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter(isWorldDir)
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
    }
}
