import Foundation

/// The quick "Report an issue" link: version, macOS and the redacted tail of a server's log, as a prefilled GitHub issue.
nonisolated enum IssueLink {
    static let maxLength = 7000

    static func logTail(serverPath: String?, maxLines: Int = 40) -> String {
        guard let serverPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: serverPath).appending(path: "logs/latest.log")) else { return "" }
        let text = String(decoding: data.suffix(64 * 1024), as: UTF8.self)
        let lines = text.split(separator: "\n").suffix(maxLines)
        return ProblemReport.redact(lines.joined(separator: "\n"))
    }

    static func url(version: String, os: String = ProcessInfo.processInfo.operatingSystemVersionString, log: String) -> URL? {
        var keep = 4000
        var result = build(version: version, os: os, log: log, keep: keep)
        while let u = result, u.absoluteString.count > maxLength, keep > 100 {
            keep = keep * 2 / 3
            result = build(version: version, os: os, log: log, keep: keep)
        }
        return result
    }

    private static func build(version: String, os: String, log: String, keep: Int) -> URL? {
        var body = "**What happened? / what do you want?**\n\n\n\n---\nCraftPanel \(version) · \(os)\n"
        if !log.isEmpty {
            let cut = log.count <= keep ? log : "…" + String(log.suffix(keep))
            body += "\n<details><summary>Server latest.log (personal details removed)</summary>\n\n```\n\(cut)\n```\n</details>\n"
        }
        var c = URLComponents(string: "https://github.com/Rashica07/OMNIServers/issues/new")!
        c.queryItems = [URLQueryItem(name: "body", value: body)]
        return c.url
    }
}
