import Foundation
import CryptoKit

/// Managed Java runtimes — port of `javainstall.rs`. Downloads an Eclipse
/// Temurin JRE from Adoptium, verifies the SHA-256 Adoptium publishes, and
/// extracts it under `~/Library/Application Support/CraftPanel/jre/<feature>/mac-<arch>/`
/// (same layout as the Rust app's data dir). This is the one feature that
/// downloads and runs a third-party binary, so the checksum is not optional.
nonisolated enum JavaInstaller {
    private static let api = "https://api.adoptium.net/v3/assets/latest"
    private static let userAgent = "CraftPanel/0.1 java-install"

    static var archName: String {
        #if arch(arm64)
        "aarch64"
        #else
        "x64"
        #endif
    }

    /// Which bundled feature version satisfies a requirement (17, 21, 25 —
    /// Adoptium has no Apple Silicon build of 8/16, same limit as Rust).
    static func offerableFeature(requiredJava: UInt32) -> UInt8? {
        switch requiredJava {
        case 17: 17
        case 21: 21
        case 25: 25
        default: nil
        }
    }

    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "CraftPanel/jre", directoryHint: .isDirectory)
    }

    static func installDir(feature: UInt8) -> URL {
        root.appending(path: "\(feature)/mac-\(archName)", directoryHint: .isDirectory)
    }

    /// The extracted `.jdk`-style bundle nests `JAVA_HOME` at `*/Contents/Home`.
    static func installedPath(feature: UInt8) -> String? {
        let dir = installDir(feature: feature)
        guard let top = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        for name in top.sorted() {
            for candidate in [dir.appending(path: "\(name)/Contents/Home/bin/java"), dir.appending(path: "\(name)/bin/java")]
            where FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    private struct Release: Decodable { let binary: Binary }
    private struct Binary: Decodable { let package: Package }
    private struct Package: Decodable { let link: String; let checksum: String; let name: String }

    static func install(feature: UInt8, progress: (ProvisionProgress) -> Void) async throws -> JavaInfo {
        if let existing = installedPath(feature: feature), let info = await JavaProbe.probe(exe: existing) {
            progress(ProvisionProgress(stage: "done", message: "Already installed.", pct: 100))
            return info
        }
        progress(ProvisionProgress(stage: "fetch", message: "Finding a Java \(feature) build for this Mac…", pct: nil))
        guard let url = URL(string: "\(api)/\(feature)/hotspot?architecture=\(archName)&image_type=jre&os=mac&vendor=eclipse") else {
            throw ProvisionError.message("bad Adoptium URL")
        }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let pkg = try? JSONDecoder().decode([Release].self, from: data).first?.binary.package,
              let link = URL(string: pkg.link), link.scheme == "https" else {
            throw ProvisionError.message("No Java \(feature) build published for this Mac (\(archName)).")
        }

        progress(ProvisionProgress(stage: "download", message: "Downloading \(pkg.name)…", pct: 0))
        var dreq = URLRequest(url: link, timeoutInterval: 300)
        dreq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (tmp, dresp) = try await URLSession.shared.download(for: dreq)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (dresp as? HTTPURLResponse)?.statusCode == 200 else {
            throw ProvisionError.message("Java download failed (HTTP \((dresp as? HTTPURLResponse)?.statusCode ?? 0)).")
        }

        progress(ProvisionProgress(stage: "verify", message: "Verifying checksum", pct: nil))
        let digest = try await Task.detached { try sha256Hex(tmp) }.value
        guard digest.caseInsensitiveCompare(pkg.checksum) == .orderedSame else {
            throw ProvisionError.message("The download didn't match the checksum Adoptium published, so OMNIServers deleted it rather than run it. Try again.")
        }

        let dest = installDir(feature: feature)
        let fm = FileManager.default
        // Previous partial install: move it to the trash rather than delete.
        if fm.fileExists(atPath: dest.path) {
            _ = try? ServerFileCollector.moveToTrash(dest, trashDir: root.appending(path: ".craftpanel-trash"))
        }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        progress(ProvisionProgress(stage: "extract", message: "Extracting…", pct: nil))
        let r = try await Subprocess.runAsync("/usr/bin/tar", ["-xzf", tmp.path, "-C", dest.path], timeout: 300)
        guard r.status == 0, let bin = installedPath(feature: feature) else {
            throw ProvisionError.message("Extracted the download but couldn't find java inside it.")
        }
        progress(ProvisionProgress(stage: "done", message: "Java installed.", pct: 100))
        guard let info = await JavaProbe.probe(exe: bin) else {
            throw ProvisionError.message("Installed Java, but couldn't get it to report a version.")
        }
        return info
    }

    private static func sha256Hex(_ url: URL) throws -> String {
        let h = FileHandle(forReadingAtPath: url.path)
        guard let h else { throw ProvisionError.message("can't read download") }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
