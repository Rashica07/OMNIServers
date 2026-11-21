import Foundation

/// A line-preserving reader/writer for `server.properties`. Direct port
/// of `properties.rs`: parse into an ordered list of lines, only rewrite
/// the lines whose key actually changed, and leave comments, blanks,
/// ordering, and untouched entries byte-for-byte. This is the hard
/// constraint carried over from the Tauri app — never touch `online-mode`
/// or anything the caller didn't explicitly set, and never reflow the
/// file.
nonisolated struct Properties {
    private enum Line {
        /// Comment or blank — kept verbatim.
        case raw(String)
        /// `key=value` entry. `raw` is the exact original text, cleared
        /// once the value is changed so `render()` knows to re-emit it.
        case entry(key: String, value: String, raw: String?)
    }

    private let dir: URL
    private var lines: [Line]
    /// File ended with a newline (or was empty/missing).
    private var trailingNewline: Bool
    let existed: Bool

    static func load(dir: URL) -> Properties {
        let path = dir.appending(path: "server.properties")
        let text = try? String(contentsOf: path, encoding: .utf8)
        let existed = text != nil
        let content = text ?? ""
        let trailingNewline = content.hasSuffix("\n") || content.isEmpty

        var lines: [Line] = []
        // `String.split` on "\n" for splitting into raw lines, matching
        // Rust's `.lines()` (which also strips a trailing \r).
        let rawLines = content.isEmpty ? [] : content.components(separatedBy: "\n").dropLastIfEmpty(whenTrailingNewline: trailingNewline)
        for raw0 in rawLines {
            let raw = raw0.hasSuffix("\r") ? String(raw0.dropLast()) : raw0
            let trimmed = raw.drop(while: { $0 == " " || $0 == "\t" })
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("!") {
                lines.append(.raw(raw))
                continue
            }
            if let (key, value) = Self.splitEntry(raw) {
                lines.append(.entry(key: key, value: value, raw: raw))
            } else {
                lines.append(.raw(raw))
            }
        }

        return Properties(dir: dir, lines: lines, trailingNewline: trailingNewline, existed: existed)
    }

    func get(_ key: String) -> String? {
        for line in lines.reversed() {
            if case .entry(let k, let v, _) = line, k == key {
                return Self.unescape(v)
            }
        }
        return nil
    }

    func getOr(_ key: String, _ fallback: String) -> String {
        get(key) ?? fallback
    }

    /// Every `key=value` entry in file order (last wins on duplicates), unescaped.
    func entries() -> [(String, String)] {
        var seen = Set<String>()
        var out: [(String, String)] = []
        for line in lines {
            if case .entry(let key, _, _) = line, seen.insert(key).inserted {
                out.append((key, get(key) ?? ""))
            }
        }
        return out
    }

    /// Set (or insert) a key. Returns true if the stored value actually changed.
    @discardableResult
    mutating func set(_ key: String, _ value: String) -> Bool {
        let escaped = Self.escapeValue(value)
        for i in lines.indices {
            if case .entry(let k, let v, _) = lines[i], k == key {
                if Self.unescape(v) == value { return false }
                lines[i] = .entry(key: k, value: escaped, raw: nil)
                return true
            }
        }
        lines.append(.entry(key: key, value: escaped, raw: nil))
        return true
    }

    func render() -> String {
        var out = ""
        for (i, line) in lines.enumerated() {
            if i > 0 { out.append("\n") }
            switch line {
            case .raw(let s): out.append(s)
            case .entry(let key, let value, let raw):
                if let raw {
                    out.append(raw)
                } else {
                    out.append(key)
                    out.append("=")
                    out.append(value)
                }
            }
        }
        if trailingNewline, !out.isEmpty {
            out.append("\n")
        }
        return out
    }

    func save() throws {
        try render().write(to: dir.appending(path: "server.properties"), atomically: true, encoding: .utf8)
    }

    // MARK: - Parsing helpers

    /// Key ends at the first unescaped `=` or `:`.
    private static func splitEntry(_ raw: String) -> (String, String)? {
        let chars = Array(raw)
        var i = 0
        var escaped = false
        while i < chars.count, chars[i] == " " || chars[i] == "\t" { i += 1 }
        let keyStart = i
        while i < chars.count {
            let c = chars[i]
            if escaped {
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "=" || c == ":" {
                let key = String(chars[keyStart..<i]).trimmingCharacters(in: .whitespaces)
                let valueChars = chars[(i + 1)...]
                let value = String(valueChars).trimmingLeadingWhitespace()
                if key.isEmpty { return nil }
                return (key, value)
            }
            i += 1
        }
        return nil
    }

    private static func unescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            if c != "\\" {
                out.append(c)
                continue
            }
            switch it.next() {
            case "n": out.append("\n")
            case "r": out.append("\r")
            case "t": out.append("\t")
            case "u":
                var hex = ""
                for _ in 0..<4 {
                    guard let h = it.next() else { break }
                    hex.append(h)
                }
                if let n = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(n) {
                    out.append(Character(scalar))
                }
            case .some(let other): out.append(other) // \: \= \\ \space
            case nil: break
            }
        }
        return out
    }

    /// Minimal, safe escaping for values we write (booleans, ports, passwords, MOTD).
    private static func escapeValue(_ v: String) -> String {
        var out = ""
        for (i, c) in v.enumerated() {
            switch c {
            case "\\": out.append("\\\\")
            case "\n": out.append("\\n")
            case "\r": out.append("\\r")
            case "\t": out.append("\\t")
            case " " where i == 0: out.append("\\ ")
            default: out.append(c)
            }
        }
        return out
    }
}

private nonisolated extension String {
    /// `String(dropping last leading/trailing whitespace)` for values —
    /// Rust's `trim_start()` equivalent.
    func trimmingLeadingWhitespace() -> String {
        String(self.drop(while: { $0 == " " || $0 == "\t" }))
    }
}

private nonisolated extension Array where Element == String {
    /// `String.components(separatedBy:)` produces a trailing empty
    /// element when the string ends with the separator — Rust's
    /// `.lines()` doesn't, so drop it here to match.
    func dropLastIfEmpty(whenTrailingNewline: Bool) -> [String] {
        if whenTrailingNewline, last == "" {
            return Array(dropLast())
        }
        return self
    }
}
