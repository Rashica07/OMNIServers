import Foundation

/// Downloads OMNI Launcher (the Minecraft launcher that goes with OMNIServers) from its GitHub releases and installs it for this user.
/// Launcher builds are published as `omni-launcher-v*` releases, currently pre-releases, so pre-releases count here.
nonisolated enum LauncherInstaller {
    static let repo = "Rashica07/omni-launcher"

    struct Release: Equatable, Sendable {
        var tag: String
        var url: URL
        var size: Int
        var assetName: String
    }

    /// The only Mac build published is Apple silicon.
    static var platform: String? {
        #if arch(arm64)
        "macos-arm64"
        #else
        nil
        #endif
    }

    /// The newest non-draft `omni-launcher-v*` release with a build for `platform` (GitHub lists newest first).
    static func pick(from releases: [[String: Any]], platform: String) -> Release? {
        for r in releases {
            let tag = (r["tag_name"] as? String) ?? ""
            guard tag.hasPrefix("omni-launcher-v"), (r["draft"] as? Bool) != true else { continue }
            for a in (r["assets"] as? [[String: Any]]) ?? [] {
                let name = (a["name"] as? String) ?? ""
                guard name.lowercased().contains(platform), name.lowercased().hasSuffix(".zip"),
                      let url = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) else { continue }
                return Release(tag: tag, url: url, size: (a["size"] as? Int) ?? 0, assetName: name)
            }
        }
        return nil
    }

    static func latest() async throws -> Release {
        guard let platform else { throw UpdateInstaller.Failure.message("There's no OMNI Launcher build for this Mac yet (only Apple silicon so far).") }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=20")!, timeoutInterval: 15)
        request.setValue("CraftPanel", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw UpdateInstaller.Failure.message("Couldn't reach GitHub. Check your internet connection and try again.")
        }
        guard let rel = pick(from: json, platform: platform) else {
            throw UpdateInstaller.Failure.message("No OMNI Launcher download is published for this Mac yet.")
        }
        return rel
    }

    private static let tagKey = "cp.launcherInstalledTag"
    static var installedTag: String? {
        get { UserDefaults.standard.string(forKey: tagKey) }
        set { UserDefaults.standard.set(newValue, forKey: tagKey) }
    }

    /// True when this app installed the launcher earlier and a different (newer) build is published now.
    static func isUpdateAvailable(installedTag: String?, latestTag: String) -> Bool {
        guard let installedTag, !installedTag.isEmpty else { return false }
        return installedTag.caseInsensitiveCompare(latestTag) != .orderedSame
    }

    /// Where the app goes: where it already is, else /Applications when writable, else ~/Applications (no admin rights needed).
    static func destination(existing: URL?, home: String = NSHomeDirectory(),
                            writable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) }) -> URL {
        if let existing { return existing }
        let root = writable("/Applications") ? "/Applications" : "\(home)/Applications"
        return URL(fileURLWithPath: root).appendingPathComponent("OMNI Launcher.app")
    }

    /// Unpacks the zip, checks the app, puts it in place (the old one is kept until the new one is in) and clears the download flag. Returns the app's location.
    static func install(zip: URL, to target: URL) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "omni-launcher-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let unzip = try Subprocess.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path], timeout: 120)
        guard unzip.status == 0 else { throw UpdateInstaller.Failure.message("Couldn't unpack the launcher download.") }
        let apps = (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "app" } ?? []
        guard let app = apps.first else { throw UpdateInstaller.Failure.message("The launcher download didn't contain an app.") }
        let exec = app.appending(path: "Contents/MacOS/omni-launcher")
        guard fm.isExecutableFile(atPath: exec.path) else { throw UpdateInstaller.Failure.message("The launcher download looks incomplete, so it wasn't installed.") }
        let verify = try Subprocess.run("/usr/bin/codesign", ["--verify", "--deep", app.path], timeout: 60)
        guard verify.status == 0 else { throw UpdateInstaller.Failure.message("The downloaded launcher failed its signature check, so it wasn't installed.") }

        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let backup = target.appendingPathExtension("old")
        try? fm.removeItem(at: backup)
        let hadOld = fm.fileExists(atPath: target.path)
        if hadOld { try fm.moveItem(at: target, to: backup) }
        let copy = try Subprocess.run("/usr/bin/ditto", [app.path, target.path], timeout: 120)
        guard copy.status == 0 else {
            try? fm.removeItem(at: target)
            if hadOld { try? fm.moveItem(at: backup, to: target) }
            throw UpdateInstaller.Failure.message("Couldn't copy the launcher into \(target.deletingLastPathComponent().path).")
        }
        try? fm.removeItem(at: backup)
        _ = try? Subprocess.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", target.path], timeout: 30)
        return target
    }

    /// Downloads the release and installs it. Returns the installed app.
    static func download(_ release: Release, existing: URL?, progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        progress("Downloading OMNI Launcher…")
        var request = URLRequest(url: release.url, timeoutInterval: 120)
        request.setValue("CraftPanel", forHTTPHeaderField: "User-Agent")
        let (tmp, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw UpdateInstaller.Failure.message("The launcher download failed. Try again in a moment.")
        }
        if release.size > 0, let size = (try? FileManager.default.attributesOfItem(atPath: tmp.path)[.size]) as? Int, size != release.size {
            throw UpdateInstaller.Failure.message("The launcher download was incomplete. Try again.")
        }
        let zip = tmp.deletingLastPathComponent().appending(path: "omni-launcher-\(UUID().uuidString).zip")
        try FileManager.default.moveItem(at: tmp, to: zip)
        defer { try? FileManager.default.removeItem(at: zip) }
        progress("Installing…")
        let app = try install(zip: zip, to: destination(existing: existing))
        installedTag = release.tag
        return app
    }
}
