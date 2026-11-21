import XCTest
@testable import craftpanel_Swift

final class UpdateCheckerTests: XCTestCase {
    func testSemverCompare() {
        XCTAssertTrue(UpdateChecker.parseSemver("v0.2.0") > UpdateChecker.parseSemver("0.1.9"))
        XCTAssertTrue(UpdateChecker.parseSemver("1.0.0") > UpdateChecker.parseSemver("0.9.9"))
        XCTAssertEqual(UpdateChecker.parseSemver("0.1.0"), SemVer(major: 0, minor: 1, patch: 0))
    }

    func testSemverToleratesPrereleaseAndBuildSuffixes() {
        XCTAssertEqual(UpdateChecker.parseSemver("2.8.1-beta"), SemVer(major: 2, minor: 8, patch: 1))
        XCTAssertEqual(UpdateChecker.parseSemver("2.8.1+build3"), SemVer(major: 2, minor: 8, patch: 1))
        XCTAssertEqual(UpdateChecker.parseSemver("v2.8.1"), SemVer(major: 2, minor: 8, patch: 1))
    }

    func testSemverEqualVersionsAreNotNewer() {
        XCTAssertFalse(UpdateChecker.parseSemver("2.8.1") > UpdateChecker.parseSemver("v2.8.1"))
    }

    private func release(_ tag: String, assets: [String] = [], draft: Bool = false) -> [String: Any] {
        ["tag_name": tag, "draft": draft, "prerelease": false, "html_url": "https://github.com/x/y/releases/tag/\(tag)", "body": "notes",
         "assets": assets.map { ["name": $0, "browser_download_url": "https://dl/\($0)"] }]
    }

    func testPicksNewestMacReleaseNotTheWindowsOne() {
        let releases = [
            release("windows-v2.9.0", assets: ["CraftPanel-2.9.0-win-x64.zip"]),
            release("swift-v2.8.1", assets: ["CraftPanel-2.8.1-AppleSilicon.dmg", "CraftPanel-2.8.1-Intel.dmg"]),
            release("swift-v2.8.2", assets: ["CraftPanel-2.8.2-AppleSilicon.dmg", "CraftPanel-2.8.2-Intel.dmg"]),
            release("swift-v2.9.9", draft: true),
        ]
        let arm = UpdateChecker.pick(from: releases, current: "2.8.1", appleSilicon: true)
        XCTAssertEqual(arm.latest, "v2.8.2")
        XCTAssertTrue(arm.newer)
        XCTAssertEqual(arm.downloadURL?.lastPathComponent, "CraftPanel-2.8.2-AppleSilicon.dmg")
        let intel = UpdateChecker.pick(from: releases, current: "2.8.1", appleSilicon: false)
        XCTAssertEqual(intel.downloadURL?.lastPathComponent, "CraftPanel-2.8.2-Intel.dmg")
        XCTAssertFalse(UpdateChecker.pick(from: releases, current: "2.8.2", appleSilicon: true).newer)
        XCTAssertNotNil(UpdateChecker.pick(from: [release("windows-v1.0.0")], current: "2.8.1", appleSilicon: true).unavailable)
    }

    func testSwapScriptWaitsForQuitQuotesPathsAndRestoresOnFailure() {
        let script = UpdateInstaller.swapScript(pid: 123, staged: URL(fileURLWithPath: "/tmp/new dir"), target: URL(fileURLWithPath: "/Applications/Craft's Panel.app"))
        XCTAssertTrue(script.contains("kill -0 123"))
        XCTAssertTrue(script.contains("'/Applications/Craft'\\''s Panel.app'"))
        XCTAssertTrue(script.contains("'/tmp/new dir/OMNIServers.app'"))
        XCTAssertTrue(script.contains("mv \"$BACKUP\""))
        XCTAssertFalse(UpdateInstaller.canReplaceInPlace(bundle: URL(fileURLWithPath: "/Volumes/CraftPanel/CraftPanel.app")))
    }

    /// A real network call, same discipline as JavaProbeTests' live probe:
    /// skips cleanly if there's no network, doesn't fake the response.
    func testLiveCheckAgainstRealGitHub() async throws {
        let result = await UpdateChecker.check()
        if let unavailable = result.unavailable {
            throw XCTSkip("No network / no releases reachable: \(unavailable)")
        }
        XCTAssertFalse(result.current.isEmpty)
        // whatever's actually published, the check must at least resolve
        // a tag without crashing on parsing it
        XCTAssertNotNil(result.latest)
    }
}

final class LauncherInstallerTests: XCTestCase {
    private func release(_ tag: String, draft: Bool = false, assets: [String]) -> [String: Any] {
        ["tag_name": tag, "draft": draft,
         "assets": assets.map { ["name": $0, "browser_download_url": "https://dl/\(tag)/\($0)", "size": 22_000_000] }]
    }

    func testPicksNewestLauncherReleaseWithAMacBuild() {
        let rels = [
            release("swift-v9.0.0", assets: ["x-macos-arm64.zip"]),
            release("omni-launcher-v0.3.0", draft: true, assets: ["OMNI-Launcher-macos-arm64.zip"]),
            release("omni-launcher-v0.2.0-dev.2", assets: ["OMNI-Launcher-windows-x64.zip"]),
            release("omni-launcher-v0.2.0-dev.1", assets: ["OMNI-Launcher-macos-arm64.zip", "OMNI-Launcher-linux-x64.tar.gz"]),
        ]
        let r = LauncherInstaller.pick(from: rels, platform: "macos-arm64")
        XCTAssertEqual(r?.tag, "omni-launcher-v0.2.0-dev.1")
        XCTAssertEqual(r?.assetName, "OMNI-Launcher-macos-arm64.zip")
        XCTAssertNil(LauncherInstaller.pick(from: rels, platform: "macos-x64"))
    }

    func testUpdateOnlyOfferedWhenThisAppInstalledAnOlderBuild() {
        XCTAssertFalse(LauncherInstaller.isUpdateAvailable(installedTag: nil, latestTag: "omni-launcher-v2"))
        XCTAssertFalse(LauncherInstaller.isUpdateAvailable(installedTag: "omni-launcher-v1", latestTag: "omni-launcher-v1"))
        XCTAssertTrue(LauncherInstaller.isUpdateAvailable(installedTag: "omni-launcher-v1", latestTag: "omni-launcher-v2"))
    }

    func testInstallLocationKeepsAnExistingCopyElseUsesAWritableApplicationsFolder() {
        let here = URL(fileURLWithPath: "/Users/x/Applications/OMNI Launcher.app")
        XCTAssertEqual(LauncherInstaller.destination(existing: here, home: "/Users/x", writable: { _ in true }), here)
        XCTAssertEqual(LauncherInstaller.destination(existing: nil, home: "/Users/x", writable: { _ in true }).path, "/Applications/OMNI Launcher.app")
        XCTAssertEqual(LauncherInstaller.destination(existing: nil, home: "/Users/x", writable: { _ in false }).path, "/Users/x/Applications/OMNI Launcher.app")
    }

    /// Builds a tiny signed .app in a zip and installs it over an older copy.
    func testInstallsAZippedAppReplacingTheOldOne() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "li-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let app = root.appending(path: "src/OMNI Launcher.app/Contents/MacOS")
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: app.appending(path: "omni-launcher"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appending(path: "omni-launcher").path)
        let plist = root.appending(path: "src/OMNI Launcher.app/Contents/Info.plist")
        try """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>omni-launcher</string><key>CFBundleIdentifier</key><string>test.omni.launcher</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
        """.write(to: plist, atomically: true, encoding: .utf8)
        XCTAssertEqual(try Subprocess.run("/usr/bin/codesign", ["--force", "--sign", "-", root.appending(path: "src/OMNI Launcher.app").path]).status, 0)
        let zip = root.appending(path: "l.zip")
        XCTAssertEqual(try Subprocess.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", root.appending(path: "src/OMNI Launcher.app").path, zip.path]).status, 0)

        let target = root.appending(path: "Applications/OMNI Launcher.app")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try "old".write(to: target.appending(path: "old.txt"), atomically: true, encoding: .utf8)
        let installed = try LauncherInstaller.install(zip: zip, to: target)
        XCTAssertEqual(installed, target)
        XCTAssertTrue(fm.isExecutableFile(atPath: target.appending(path: "Contents/MacOS/omni-launcher").path))
        XCTAssertFalse(fm.fileExists(atPath: target.appending(path: "old.txt").path), "the old copy is replaced")
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathExtension("old").path), "no backup left behind")
    }

    func testRejectsAZipWithoutAnApp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "li-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appending(path: "src"), withIntermediateDirectories: true)
        try "hi".write(to: root.appending(path: "src/readme.txt"), atomically: true, encoding: .utf8)
        let zip = root.appending(path: "l.zip")
        _ = try Subprocess.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", root.appending(path: "src").path, zip.path])
        XCTAssertThrowsError(try LauncherInstaller.install(zip: zip, to: root.appending(path: "A/OMNI Launcher.app")))
    }

    func testSwapScriptOnlyRelaunchesWhenAsked() {
        let staged = URL(fileURLWithPath: "/tmp/new"), target = URL(fileURLWithPath: "/Applications/OMNIServers.app")
        XCTAssertTrue(UpdateInstaller.swapScript(pid: 1, staged: staged, target: target).contains("open '/Applications/OMNIServers.app'"))
        XCTAssertFalse(UpdateInstaller.swapScript(pid: 1, staged: staged, target: target, relaunch: false).contains("open '"))
    }

    /// Real GitHub download of the newest launcher build into a temp folder. Off unless `OMNI_LIVE=1`.
    func testLiveDownloadAndInstallFromGitHub() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OMNI_LIVE"] == "1", "set OMNI_LIVE=1 to run")
        let release = try await LauncherInstaller.latest()
        let target = FileManager.default.temporaryDirectory.appending(path: "live-\(UUID().uuidString)/OMNI Launcher.app")
        defer { try? FileManager.default.removeItem(at: target.deletingLastPathComponent()) }
        let app = try await LauncherInstaller.download(release, existing: target) { _ in }
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: app.appending(path: "Contents/MacOS/omni-launcher").path))
        print("LIVE installed", release.tag)
    }
}
