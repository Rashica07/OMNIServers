import AppKit

/// The hand-off from OMNIServers to OMNI Launcher (the Minecraft launcher). Servers live here;
/// playing lives there.
enum OMNILauncherLink {
    /// Where the launcher app may be installed, best guess first.
    static func candidatePaths(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications/OMNI Launcher.app", "\(home)/Applications/OMNI Launcher.app",
         "/Applications/OMNILauncher.app", "\(home)/Applications/OMNILauncher.app"]
    }

    static func installedURL(fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
                             home: String = NSHomeDirectory()) -> URL? {
        candidatePaths(home: home).first(where: fileExists).map { URL(fileURLWithPath: $0) }
    }

    /// What OMNIServers asks the launcher to join: written as `join-request.json` into the launcher's
    /// data folder, which the launcher picks up and answers with its Join popup.
    struct JoinRequest: Codable, Equatable {
        var name: String
        /// The address on this computer.
        var address: String
        /// The address friends outside use (a tunnel or a saved permanent address), if there is one.
        var publicAddress: String?
        var minecraft: String
        /// Seconds since 1970.
        var created: Int

        enum CodingKeys: String, CodingKey {
            case name, address, minecraft, created
            case publicAddress = "public_address"
        }
    }

    /// Where the launcher looks for a request: its data folder (the launcher's `omni-launcher`).
    static func requestURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/omni-launcher/join-request.json")
    }

    static func encode(_ request: JoinRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(request)
    }

    /// A launcher started from source keeps its data in `~/.omni-launcher-dev` (HORIZON_LAUNCHER_HOME),
    /// not next to the installed app. It watches that folder, so requests go there too when it exists.
    static func devRequestURL(home: String = NSHomeDirectory()) -> URL? {
        let dir = URL(fileURLWithPath: home).appendingPathComponent(".omni-launcher-dev")
        return FileManager.default.fileExists(atPath: dir.path) ? dir.appendingPathComponent("join-request.json") : nil
    }

    /// Every place a launcher may be watching.
    static func requestURLs(home: String = NSHomeDirectory()) -> [URL] {
        [requestURL(home: home)] + (devRequestURL(home: home).map { [$0] } ?? [])
    }

    /// Writes the request where the launcher will find it.
    static func write(_ request: JoinRequest, to url: URL = requestURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encode(request).write(to: url, options: .atomic)
    }

    /// Writes the request to every place a launcher may be watching. Throws only if none worked.
    static func writeEverywhere(_ request: JoinRequest, urls: [URL] = requestURLs()) throws {
        var firstError: Error?
        var wrote = false
        for u in urls {
            do { try write(request, to: u); wrote = true } catch { firstError = firstError ?? error }
        }
        if !wrote, let e = firstError { throw e }
    }

    /// True while a launcher process is running, installed as an app or started from source.
    static func isRunning() -> Bool {
        guard let r = try? Subprocess.run("/usr/bin/pgrep", ["-x", "omni-launcher"], timeout: 3) else { return false }
        return r.status == 0
    }

    /// Whether Play can go through the launcher: it is installed and the server has a Minecraft version.
    static func canPlay(minecraft: String?, installed: Bool = installedURL() != nil || isRunning()) -> Bool {
        installed && !(minecraft?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
    }

    /// Asks the launcher to join this server and opens it. False when it could not be done, so the
    /// caller can fall back to the old way.
    @discardableResult
    static func play(name: String, address: String, publicAddress: String?, minecraft: String) -> Bool {
        let request = JoinRequest(name: name, address: address, publicAddress: publicAddress,
                                  minecraft: minecraft, created: Int(Date().timeIntervalSince1970))
        guard (try? writeEverywhere(request)) != nil else { return false }
        return open() || isRunning()
    }

    /// Opens the launcher. Returns false when it is not installed, so the caller can say so.
    @discardableResult
    static func open() -> Bool {
        guard let url = installedURL() else { return false }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return true
    }
}
