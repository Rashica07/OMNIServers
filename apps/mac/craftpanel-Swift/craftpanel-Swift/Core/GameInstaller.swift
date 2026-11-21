import Foundation

/// "Make a new one" for Terraria (FiveM has no macOS server): downloads the official server into an empty folder, then repairs the setup.
nonisolated enum GameInstaller {
    static let terrariaNames = "https://terraria.org/api/get/dedicated-servers-names"
    static let terrariaDownload = "https://terraria.org/api/download/pc-dedicated-server/"

    /// The newest `terraria-server-NNNN.zip` name out of terraria.org's JSON list.
    static func parseTerrariaFile(_ json: Data) -> String? {
        guard let names = try? JSONDecoder().decode([String].self, from: json) else { return nil }
        return names.first { $0.hasPrefix("terraria-server-") && $0.hasSuffix(".zip") }
    }

    static func createTerraria(dir: URL, name: String, progress: @escaping (ProvisionProgress) -> Void) async throws -> Created {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let items = try? fm.contentsOfDirectory(atPath: dir.path), !items.isEmpty {
            throw ProvisionError.message("That folder isn't empty. Pick a fresh folder for a new server.")
        }
        progress(ProvisionProgress(stage: "lookup", message: "Finding the newest Terraria server…", pct: nil))
        guard let listURL = URL(string: terrariaNames) else { throw ProvisionError.message("bad URL") }
        let (listData, _) = try await URLSession.shared.data(from: listURL)
        guard let file = parseTerrariaFile(listData) else { throw ProvisionError.message("Couldn't find the latest Terraria server. Try again in a minute.") }

        let zip = dir.appending(path: ".terraria.zip")
        try await Provisioner.downloadTo(terrariaDownload + file, dest: zip, label: "Terraria server", progress: progress)
        progress(ProvisionProgress(stage: "unpack", message: "Unpacking the server", pct: nil))
        let stage = dir.appending(path: ".stage")
        let r = try await Subprocess.runAsync("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", stage.path], timeout: 300)
        try? fm.removeItem(at: zip)
        guard r.status == 0 else { throw ProvisionError.message("Couldn't unpack the Terraria download.") }
        let mac = (fm.enumerator(at: stage, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.first { $0.lastPathComponent == "Mac" })
        guard let mac else { throw ProvisionError.message("The Terraria download had no server for this Mac.") }
        for item in try fm.contentsOfDirectory(atPath: mac.path) {
            try fm.moveItem(at: mac.appending(path: item), to: dir.appending(path: item))
        }
        try? fm.removeItem(at: stage)

        progress(ProvisionProgress(stage: "fix", message: "Setting it up", pct: nil))
        guard let found = GameServers.inspect(at: dir) else { throw ProvisionError.message("The download didn't contain the server program.") }
        // The launchers inside the app bundle must be executable.
        let macos = dir.appending(path: "Terraria Server.app/Contents/MacOS")
        for f in (try? fm.contentsOfDirectory(atPath: macos.path)) ?? [] {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: macos.appending(path: f).path, isDirectory: &isDir), !isDir.boolValue {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macos.appending(path: f).path)
            }
        }
        _ = GameServers.fix(type: .terraria, dir: dir, name: name)
        return Created(serverType: .terraria, launchTarget: found.launchTarget, mcVersion: "", dir: dir, javaPath: "")
    }
}
