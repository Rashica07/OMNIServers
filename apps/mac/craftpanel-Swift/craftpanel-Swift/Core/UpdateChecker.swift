import Foundation

/// Result of a "is there something newer" check. Mirrors
/// `updater::UpdateCheck` field-for-field. `nonisolated` because it's a
/// plain value crossing from a background `URLSession` call back to the
/// view — the file's default MainActor isolation would otherwise make it
/// awkward to construct off the main actor for no real reason.
nonisolated struct UpdateCheck: Sendable, Equatable {
    var current: String
    var latest: String?
    var newer: Bool
    var url: URL?
    var notes: String?
    /// The .dmg for this Mac's chip, when the release has one.
    var downloadURL: URL?
    /// No repo configured / offline / no releases published yet.
    var unavailable: String?
}

/// Launch-time "is there a newer release" check against GitHub Releases —
/// the game-launcher pattern: check automatically on open, surface a
/// banner if there's something newer, never block startup on it.
///
/// This is deliberately the check-only half of `updater.rs`. The other
/// half — download, verify the signature, install, relaunch — is
/// `tauri-plugin-updater` on the Tauri side; its native equivalent is
/// Sparkle, which needs its own dependency, its own appcast feed, and its
/// own code-signing setup. That's real scope, tracked as Batch H's
/// updater item in the plan rather than rushed in here. For now "auto
/// update search on launch" gets you the actual ask — automatic
/// detection with a one-click link to the release — without silently
/// skipping the harder signed-install half.
nonisolated enum UpdateChecker {

    /// Same default as the Tauri app's `DEFAULT_REPO` — baked in, not a
    /// per-user setting, so nobody running OMNIServers needs to know or
    /// care what repo it checks against. A fork points at itself by
    /// setting `CRAFTPANEL_REPO` before building the scheme, same
    /// mechanism as the Rust side.
    private static var repo: String {
        if let override_ = ProcessInfo.processInfo.environment["CRAFTPANEL_REPO"], !override_.isEmpty {
            return override_
        }
        return "Rashica07/OMNIServers"
    }

    private static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Releases of both apps live in one repo (`swift-v*` is the Mac app, `windows-v*` the Windows one), so "latest" would often be the other app's. Picks the newest `swift-v*` release and the DMG built for this chip.
    static func pick(from releases: [[String: Any]], current: String, appleSilicon: Bool) -> UpdateCheck {
        let wanted = appleSilicon ? "applesilicon" : "intel"
        let candidates = releases.filter {
            (($0["tag_name"] as? String) ?? "").hasPrefix("swift-v") && ($0["draft"] as? Bool) != true && ($0["prerelease"] as? Bool) != true
        }
        guard let best = candidates.max(by: { parseSemver(($0["tag_name"] as? String) ?? "") < parseSemver(($1["tag_name"] as? String) ?? "") }) else {
            return UpdateCheck(current: current, latest: nil, newer: false, url: nil, notes: nil, downloadURL: nil,
                               unavailable: "No Mac release is published yet.")
        }
        let tag = (best["tag_name"] as? String) ?? ""
        let version = tag.replacingOccurrences(of: "swift-", with: "")
        let assets = (best["assets"] as? [[String: Any]]) ?? []
        let dmg = assets.first {
            let n = (($0["name"] as? String) ?? "").lowercased()
            return n.hasSuffix(".dmg") && n.contains(wanted)
        }
        let notes = (best["body"] as? String).map { body in
            body.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).joined(separator: "\n")
        }
        return UpdateCheck(
            current: current,
            latest: version,
            newer: parseSemver(version) > parseSemver(current),
            url: (best["html_url"] as? String).flatMap(URL.init(string:)),
            notes: notes,
            downloadURL: (dmg?["browser_download_url"] as? String).flatMap(URL.init(string:)),
            unavailable: nil
        )
    }

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    static func check() async -> UpdateCheck {
        let current = currentVersion
        let fail = "Couldn't reach GitHub. Check your internet connection and try again."
        guard let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=30") else {
            return UpdateCheck(current: current, latest: nil, newer: false, url: nil, notes: nil, downloadURL: nil, unavailable: fail)
        }
        var request = URLRequest(url: apiURL, timeoutInterval: 10)
        request.setValue("CraftPanel", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return UpdateCheck(current: current, latest: nil, newer: false, url: nil, notes: nil, downloadURL: nil, unavailable: fail)
        }
        return pick(from: json, current: current, appleSilicon: isAppleSilicon)
    }

    /// Same tolerant parsing as the Rust side: strips a leading `v`,
    /// splits on `.`/`-`/`+`, keeps only the numeric leading run — so
    /// `v2.8.1`, `2.8.1-beta`, and `2.8.1+build3` all compare sanely.
    static func parseSemver(_ s: String) -> SemVer {
        var str = s.trimmingCharacters(in: .whitespaces)
        for prefix in ["swift-", "windows-"] where str.hasPrefix(prefix) { str.removeFirst(prefix.count) }
        if str.hasPrefix("v") { str.removeFirst() }
        let parts = str.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "+" })
            .compactMap { Int($0) }
        return SemVer(
            major: parts.count > 0 ? parts[0] : 0,
            minor: parts.count > 1 ? parts[1] : 0,
            patch: parts.count > 2 ? parts[2] : 0
        )
    }
}

/// A plain, comparable (major, minor, patch) triple — a named struct
/// rather than a bare tuple so it can conform to `Equatable`/`Comparable`
/// for tests and callers alike.
nonisolated struct SemVer: Equatable, Comparable, Sendable {
    var major: Int
    var minor: Int
    var patch: Int

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
