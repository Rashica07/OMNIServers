import Foundation

/// Downloads the release DMG, swaps the running app for the new one, and relaunches. Everything is plain files and `hdiutil`/`ditto`, so it needs no signing key or appcast feed.
nonisolated enum UpdateInstaller {
    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
    }

    /// Whether this copy of the app can replace itself where it lives (not on a read-only disk image, and the folder is writable).
    static func canReplaceInPlace(bundle: URL = Bundle.main.bundleURL) -> Bool {
        let fm = FileManager.default
        return bundle.pathExtension == "app"
            && !bundle.path.hasPrefix("/Volumes/")
            && fm.isWritableFile(atPath: bundle.deletingLastPathComponent().path)
    }

    /// Downloads, unpacks and verifies the new app. Returns the folder holding `CraftPanel.app`, ready for `swapAndRelaunch`.
    static func prepare(dmg: URL, progress: @escaping @Sendable (String) -> Void) async throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appending(path: "craftpanel-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        progress("Downloading the update…")
        var request = URLRequest(url: dmg, timeoutInterval: 60)
        request.setValue("CraftPanel", forHTTPHeaderField: "User-Agent")
        let (tmp, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw Failure.message("The download failed. Try again, or get it from the Releases page.")
        }
        let image = work.appending(path: "update.dmg")
        try fm.moveItem(at: tmp, to: image)

        progress("Unpacking…")
        let mount = work.appending(path: "mount")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = try Subprocess.run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-noverify", "-mountpoint", mount.path], timeout: 120)
        guard attach.status == 0 else { throw Failure.message("Couldn't open the downloaded disk image.") }
        defer { _ = try? Subprocess.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], timeout: 60) }

        let apps = (try? fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "app" } ?? []
        guard let app = apps.first else { throw Failure.message("The update didn't contain an app.") }
        let staged = work.appending(path: "new")
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        let copy = try Subprocess.run("/usr/bin/ditto", [app.path, staged.appending(path: "OMNIServers.app").path], timeout: 120)
        guard copy.status == 0 else { throw Failure.message("Couldn't copy the new version.") }

        let check = try Subprocess.run("/usr/bin/codesign", ["--verify", "--deep", staged.appending(path: "OMNIServers.app").path], timeout: 60)
        guard check.status == 0 else { throw Failure.message("The downloaded app failed its signature check, so it wasn't installed.") }
        return staged
    }

    /// The shell script that waits for this app to quit, replaces it, and opens the new one.
    static func swapScript(pid: Int32, staged: URL, target: URL, relaunch: Bool = true) -> String {
        func q(_ u: URL) -> String { "'" + u.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let new = staged.appending(path: "OMNIServers.app")
        return """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        BACKUP=\(q(target)).old
        rm -rf "$BACKUP"
        mv \(q(target)) "$BACKUP" || exit 1
        if ditto \(q(new)) \(q(target)); then rm -rf "$BACKUP"; else rm -rf \(q(target)); mv "$BACKUP" \(q(target)); fi
        \(relaunch ? "open \(q(target))" : "")
        """
    }

    static func swapAndRelaunch(staged: URL, target: URL = Bundle.main.bundleURL, relaunch: Bool = true) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", swapScript(pid: ProcessInfo.processInfo.processIdentifier, staged: staged, target: target, relaunch: relaunch)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}
