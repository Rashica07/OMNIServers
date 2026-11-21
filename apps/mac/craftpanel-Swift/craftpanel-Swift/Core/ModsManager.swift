import Foundation

/// `mods/` folder management for Fabric/Forge servers -- distinct from
/// AddonsView's Modrinth-tracked installed list: this manages *every*
/// jar in the folder, including ones dropped in manually outside
/// OMNIServers entirely. Direct port of `mods.rs`.
///
/// Enable/disable = move a jar between `mods/` and `mods-disabled/`.
/// Removing a jar moves it to `.craftpanel-trash/` rather than deleting
/// it outright -- same standing rule as everywhere else in this app.
nonisolated struct ModFile: Sendable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    var size: UInt64
    var enabled: Bool
}

nonisolated struct ModList: Sendable {
    /// This loader loads from a `mods/` folder at all.
    var supported: Bool
    var mods: [ModFile] = []
    /// Fabric/Quilt: the Fabric API jar is present and enabled.
    var fabricAPIPresent: Bool = false
    /// Offline-auth "cracked protection" mods recognised by name.
    var authMods: [String] = []
    var warnings: [String] = []
}

nonisolated enum ModsManager {
    private static let modsDir = "mods"
    private static let disabledDir = "mods-disabled"
    private static let trash = ".craftpanel-trash"

    private static let authModKeys = [
        "easyauth", "simpleauth", "simplelogin", "authme", "fabricauth", "openlogin",
        "nlogin", "ultimateauth", "dynmap-auth", "loginsecurity", "authmevelocity",
    ]

    static func loaderUsesMods(_ type: ServerType) -> Bool {
        type == .fabric || type == .forge
    }

    private static func safeJarName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("\\")
            && name != "." && name != ".." && name.lowercased().hasSuffix(".jar")
    }

    private static func readJars(_ dir: URL, enabled: Bool) -> [ModFile] {
        var out: [ModFile] = []
        let fm = FileManager.default
        if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
            for name in names where name.lowercased().hasSuffix(".jar") {
                let size = (try? fm.attributesOfItem(atPath: dir.appendingPathComponent(name).path)[.size] as? NSNumber)?.uint64Value ?? 0
                out.append(ModFile(name: name, size: size, enabled: enabled))
            }
        }
        return out.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    static func list(serverDir: URL, serverType: ServerType) -> ModList {
        guard loaderUsesMods(serverType) else {
            return ModList(
                supported: false,
                warnings: ["\(serverType.label) servers use plugins, not a mods/ folder."]
            )
        }

        var mods = readJars(serverDir.appendingPathComponent(modsDir), enabled: true)
        mods.append(contentsOf: readJars(serverDir.appendingPathComponent(disabledDir), enabled: false))

        let fabricAPIPresent = mods.contains { m in
            let n = m.name.lowercased()
            return m.enabled && (n.contains("fabric-api") || n.contains("fabric_api") || n.contains("qsl") || n.contains("quilted-fabric-api"))
        }

        let authMods = mods.filter { m in
            let n = m.name.lowercased()
            return authModKeys.contains { n.contains($0) }
        }.map(\.name)

        var warnings: [String] = []
        if serverType == .fabric, !fabricAPIPresent, !mods.isEmpty {
            warnings.append("No Fabric API jar detected in mods/. Most Fabric mods need it — add fabric-api.")
        }

        return ModList(supported: true, mods: mods, fabricAPIPresent: fabricAPIPresent, authMods: authMods, warnings: warnings)
    }

    static func setEnabled(serverDir: URL, name: String, enable: Bool) throws {
        guard safeJarName(name) else { throw RconServiceError.message("Invalid mod filename.") }
        let from = serverDir.appendingPathComponent(enable ? disabledDir : modsDir).appendingPathComponent(name)
        let to = serverDir.appendingPathComponent(enable ? modsDir : disabledDir).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: from.path) else {
            throw RconServiceError.message("\(name) isn't where expected.")
        }
        try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try moveFile(from: from, to: to)
    }

    @discardableResult
    static func importJars(serverDir: URL, sources: [URL]) throws -> [String] {
        let modsPath = serverDir.appendingPathComponent(modsDir)
        try FileManager.default.createDirectory(at: modsPath, withIntermediateDirectories: true)
        var added: [String] = []
        for src in sources {
            let name = src.lastPathComponent
            guard name.lowercased().hasSuffix(".jar") else {
                throw RconServiceError.message("\(name) isn't a .jar")
            }
            do {
                try FileManager.default.copyItem(at: src, to: modsPath.appendingPathComponent(name))
                added.append(name)
            } catch {
                throw RconServiceError.message("\(name): \(error.localizedDescription)")
            }
        }
        return added
    }

    static func remove(serverDir: URL, name: String) throws {
        guard safeJarName(name) else { throw RconServiceError.message("Invalid mod filename.") }
        let trashDir = serverDir.appendingPathComponent(trash)
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        for base in [modsDir, disabledDir] {
            let p = serverDir.appendingPathComponent(base).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: p.path) {
                try moveFile(from: p, to: trashDir.appendingPathComponent(name))
                return
            }
        }
        throw RconServiceError.message("\(name) not found.")
    }

    private static func moveFile(from: URL, to: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: to.path) {
            // Never delete: a same-named file already there is itself trashed.
            try ServerFileCollector.moveToTrash(to, trashDir: to.deletingLastPathComponent()
                .deletingLastPathComponent().appending(path: ".craftpanel-trash"))
        }
        do {
            try fm.moveItem(at: from, to: to)
        } catch {
            // cross-device (rare): copy then delete
            try fm.copyItem(at: from, to: to)
            try fm.removeItem(at: from)
        }
    }
}
