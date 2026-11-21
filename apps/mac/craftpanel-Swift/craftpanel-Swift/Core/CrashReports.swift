import Foundation

/// Reads `crash-reports/*.txt` — surfaces the latest crash, its cause
/// line, and a best guess at the culprit mod from the stack trace.
/// Direct port of `crashreports.rs`.
nonisolated struct MissingDependency: Sendable, Equatable {
    /// the missing mod's id, e.g. "terrablender" — what to search Modrinth for
    var modID: String
    /// the mod that needs it, e.g. "biomesoplenty"
    var requestedBy: String
}

nonisolated struct CrashReport: Sendable, Identifiable {
    var id: String { file }
    var file: String
    /// "2026-08-30 01:23:45" from the report, if present
    var time: String?
    /// file mtime, unix — for sorting / "how long ago"
    var mtime: Int64
    var description: String?
    /// the top exception line, e.g. "java.lang.NullPointerException: ..."
    var headline: String?
    /// best guess at the offending mod / package
    var suspect: String?
    var missingDependency: MissingDependency?
}

nonisolated enum CrashReports {
    private static let vanillaRoots = [
        "net.minecraft", "net.minecraftforge", "net.neoforged", "com.mojang",
        "java.", "javax.", "sun.", "jdk.", "io.netty", "cpw.mods", "net.fabricmc",
        "org.spongepowered", "org.slf4j", "org.apache", "com.google", "it.unimi",
        "oshi.", "joptsimple",
    ]

    private static func mtime(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else { return 0 }
        return Int64(date.timeIntervalSince1970)
    }

    static func parse(file: String, mtime: Int64, text: String) -> CrashReport {
        var time: String?, description: String?, headline: String?

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let v = stripPrefix(t, "Time: ") {
                time = v.trimmingCharacters(in: .whitespaces)
            } else if let v = stripPrefix(t, "Description: ") {
                description = v.trimmingCharacters(in: .whitespaces)
            } else if headline == nil,
                      (t.contains("Exception") || t.contains("Error")),
                      (t.contains(".") || t.contains(":")),
                      !t.hasPrefix("at "), !t.hasPrefix("//"), !t.hasPrefix("#") {
                headline = t
            }
        }

        // explicit "Suspected Mods:" (Forge) wins
        var suspect: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if let v = stripPrefix(t, "Suspected Mods:") {
                let trimmed = v.trimmingCharacters(in: .whitespaces).trimmingTrailingDots()
                if !trimmed.isEmpty, trimmed.lowercased() != "none" {
                    suspect = trimmed
                    break
                }
            }
        }
        if suspect == nil { suspect = suspectFromStack(text) }

        return CrashReport(
            file: file, time: time, mtime: mtime, description: description,
            headline: headline, suspect: suspect, missingDependency: missingDependency(text)
        )
    }

    private static func stripPrefix(_ s: String, _ prefix: String) -> String? {
        s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : nil
    }

    /// Parses `Mod ID: '<id>', Requested by: '<other id>', ... Actual
    /// version: '[MISSING]'`. One line, three quoted fields in a fixed
    /// order — real Forge/NeoForge output, not invented.
    private static func missingDependency(_ text: String) -> MissingDependency? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let rest0 = stripPrefix(t, "Mod ID: '") else { continue }
            guard let q1 = rest0.firstIndex(of: "'") else { continue }
            let modID = String(rest0[rest0.startIndex..<q1])
            let rest1 = String(rest0[rest0.index(after: q1)...])
            guard let rest2 = stripPrefix(rest1, ", Requested by: '") else { continue }
            guard let q2 = rest2.firstIndex(of: "'") else { continue }
            let requestedBy = String(rest2[rest2.startIndex..<q2])
            let rest3 = String(rest2[rest2.index(after: q2)...])
            if rest3.contains("Actual version: '[MISSING]'") {
                return MissingDependency(modID: modID, requestedBy: requestedBy)
            }
        }
        return nil
    }

    private static func suspectFromStack(_ text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let rest = stripPrefix(t, "at ") else { continue }
            // "at pkg.sub.Class.method(Class.java:12) ~[mod.jar:?]"
            let path = rest.split(separator: "(", maxSplits: 1).first.map(String.init) ?? ""
            if path.isEmpty || vanillaRoots.contains(where: { path.hasPrefix($0) }) { continue }

            // jar hint in brackets: ~[coolmod-1.2.jar:?]
            if let bracket = rest.firstIndex(of: "[") {
                let afterBracket = rest[rest.index(after: bracket)...]
                let jar = afterBracket.split(whereSeparator: { $0 == ":" || $0 == "]" }).first.map(String.init) ?? ""
                if jar.hasSuffix(".jar"), !jar.contains("minecraft"), !jar.contains("forge") {
                    return jar
                }
            }
            let root = path.split(separator: ".").prefix(2)
            if root.count == 2 { return root.joined(separator: ".") }
        }
        return nil
    }

    static func latest(serverDir: URL) -> CrashReport? {
        list(serverDir: serverDir).first
    }

    static func list(serverDir: URL) -> [CrashReport] {
        let dir = serverDir.appendingPathComponent("crash-reports")
        var reports: [CrashReport] = []
        let fm = FileManager.default
        if let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in entries where url.pathExtension == "txt" {
                let name = url.lastPathComponent
                let mt = mtime(url)
                let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                reports.append(parse(file: name, mtime: mt, text: text))
            }
        }
        reports.sort { $0.mtime > $1.mtime }
        return Array(reports.prefix(20))
    }
}

nonisolated private extension String {
    func trimmingTrailingDots() -> String {
        var s = self
        while s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
