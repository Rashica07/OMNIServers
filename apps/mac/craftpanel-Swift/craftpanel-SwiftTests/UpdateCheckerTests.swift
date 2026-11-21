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
