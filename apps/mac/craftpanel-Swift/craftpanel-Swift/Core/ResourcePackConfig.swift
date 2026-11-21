import Foundation
import CryptoKit

/// Server resource pack — a URL + SHA-1 pushed to every joining client
/// via `server.properties` (`resource-pack` / `resource-pack-sha1` /
/// `resource-pack-prompt` / `require-resource-pack`). Direct port of
/// `resourcepack.rs`.
///
/// OMNIServers doesn't host the pack itself — nothing here turns this
/// Mac into a public file server. You host the `.zip` somewhere
/// reachable and paste the direct link; OMNIServers downloads it once,
/// purely to compute the SHA-1 the client needs to verify the download,
/// and never stores the bytes.
///
/// Java-edition only — Bedrock's resource packs are a completely
/// different, folder-based system, not a URL; the UI hides this section
/// for Bedrock servers (same gating `ServerSection.applies(to:)` already
/// does).
nonisolated struct ResourcePackConfig: Sendable, Equatable {
    var url: String
    var sha1: String
    var prompt: String
    var required: Bool
}

nonisolated enum ResourcePackManager {
    static func read(dir: URL) -> ResourcePackConfig {
        let props = Properties.load(dir: dir)
        return ResourcePackConfig(
            url: props.getOr("resource-pack", ""),
            sha1: props.getOr("resource-pack-sha1", ""),
            prompt: props.getOr("resource-pack-prompt", ""),
            required: props.getOr("require-resource-pack", "false") == "true"
        )
    }

    /// Downloads the pack once just to hash it, then writes all four
    /// properties in one line-preserving pass. `url` must be a direct,
    /// publicly-reachable link to the `.zip` — not a webpage that links
    /// to one.
    static func setFromURL(dir: URL, url rawURL: String, prompt: String, required: Bool) async throws -> ResourcePackConfig {
        let trimmed = rawURL.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw RconServiceError.message("Paste a resource pack URL first.")
        }
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
            throw RconServiceError.message("That doesn't look like a URL — it should start with http:// or https://")
        }
        guard let url = URL(string: trimmed) else {
            throw RconServiceError.message("That doesn't look like a valid URL.")
        }

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("CraftPanel", forHTTPHeaderField: "User-Agent")

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw RconServiceError.message("Couldn't download that URL: \(error.localizedDescription)")
        }
        // a 200 MB sanity cap -- a resource pack this big is almost
        // certainly a mistake, matches the Rust source's take() limit.
        guard data.count <= 200 * 1024 * 1024 else {
            throw RconServiceError.message("That file is unexpectedly large for a resource pack (over 200 MB) — double-check the URL.")
        }

        // a real zip starts "PK" (local file header signature) -- catches
        // the common mistake of pasting a webpage's URL instead of the file's
        guard data.count >= 4, data.prefix(2).elementsEqual([0x50, 0x4b]) else {
            throw RconServiceError.message("That doesn't look like a .zip file — resource packs need to be zipped, and the link needs to point straight at the file.")
        }

        let digest = Insecure.SHA1.hash(data: data)
        let sha1 = digest.map { String(format: "%02x", $0) }.joined()

        return try write(dir: dir, url: trimmed, sha1: sha1, prompt: prompt, required: required)
    }

    /// Same as `setFromURL`, but for a source that already published its
    /// own SHA-1 (Modrinth's version API does, for every file) — skips
    /// downloading the whole zip a second time just to re-hash it.
    static func setKnown(dir: URL, url: String, sha1: String, prompt: String, required: Bool) throws -> ResourcePackConfig {
        try write(dir: dir, url: url, sha1: sha1, prompt: prompt, required: required)
    }

    private static func write(dir: URL, url: String, sha1: String, prompt: String, required: Bool) throws -> ResourcePackConfig {
        var props = Properties.load(dir: dir)
        props.set("resource-pack", url)
        props.set("resource-pack-sha1", sha1)
        props.set("resource-pack-prompt", prompt)
        props.set("require-resource-pack", required ? "true" : "false")
        try props.save()
        return ResourcePackConfig(url: url, sha1: sha1, prompt: prompt, required: required)
    }

    static func clear(dir: URL) throws {
        var props = Properties.load(dir: dir)
        props.set("resource-pack", "")
        props.set("resource-pack-sha1", "")
        props.set("resource-pack-prompt", "")
        props.set("require-resource-pack", "false")
        try props.save()
    }
}
