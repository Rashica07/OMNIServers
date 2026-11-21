import SwiftUI

/// A deliberately small, line-oriented syntax highlighter for the config
/// formats people actually open in the Files tab — YAML, JSON,
/// `.properties`, TOML. Direct port of `highlightConfig.ts`: not a real
/// parser, each line is tokenized independently by hand-rolled scanning
/// (mirroring the TS regexes), good enough to make a 200-line
/// `server.properties` or plugin config scannable without pulling in a
/// full editor library. Never throws — a highlighter that chokes on
/// invalid YAML while someone is mid-edit *fixing* invalid YAML would be
/// actively hostile, so anything unrecognized just falls through as
/// plain, unstyled text (every function here is total, not partial).
enum ConfigLang {
    case json, yaml, properties, toml, plain

    /// Matches `langForFile` exactly, including the `.mcmeta` -> json case.
    static func forFile(_ rel: String) -> ConfigLang {
        let ext = (rel as NSString).pathExtension.lowercased()
        switch ext {
        case "json", "mcmeta": return .json
        case "yml", "yaml": return .yaml
        case "properties": return .properties
        case "toml": return .toml
        default: return .plain
        }
    }
}

enum TokenClass {
    case comment, key, string, number, keyword, section

    var color: Color {
        switch self {
        case .comment: return CPColor.inkGhost
        case .key: return CPColor.accentSoft
        case .string: return CPColor.ok
        case .number: return CPColor.info
        case .keyword: return CPColor.warnSoft
        case .section: return CPColor.accentSoft
        }
    }

    var italic: Bool { self == .comment }
    var semibold: Bool { self == .section }
}

struct HLToken {
    let text: String
    let cls: TokenClass?
}

enum ConfigHighlighter {
    static func highlightLine(_ line: String, lang: ConfigLang) -> [HLToken] {
        switch lang {
        case .properties: return tokenizeProperties(line)
        case .yaml: return tokenizeYaml(line)
        case .toml: return tokenizeToml(line)
        case .json: return tokenizeJson(line)
        case .plain: return [HLToken(text: line, cls: nil)]
        }
    }

    // MARK: - Shared helpers

    private static func push(_ out: inout [HLToken], _ text: String, _ cls: TokenClass? = nil) {
        if !text.isEmpty { out.append(HLToken(text: text, cls: cls)) }
    }

    /// Leading whitespace, then the rest of the line.
    private static func splitLeading(_ line: String) -> (String, String) {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        let lead = String(line.prefix(line.count - trimmed.count))
        return (lead, String(trimmed))
    }

    /// Index (as a String offset) of a `#` that starts a trailing comment
    /// — not one inside quotes. `nil` if there isn't one.
    private static func unquotedHash(_ s: String) -> String.Index? {
        var quote: Character?
        var prev: Character?
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "#" && (i == s.startIndex || prev == " ") {
                return i
            }
            prev = c
            i = s.index(after: i)
        }
        return nil
    }

    private static func tokenizeScalar(_ text: String, _ out: inout [HLToken]) {
        let hashIdx = unquotedHash(text)
        let value = hashIdx.map { String(text[text.startIndex..<$0]) } ?? text
        let comment = hashIdx.map { String(text[$0...]) } ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            push(&out, value, .string)
        } else if matches(trimmed, #"^(?i:true|false|null|~|yes|no)$"#) {
            push(&out, value, .keyword)
        } else if matches(trimmed, #"^-?\d+(\.\d+)?$"#) {
            push(&out, value, .number)
        } else {
            push(&out, value, nil)
        }
        push(&out, comment, .comment)
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: .regularExpression) != nil
    }

    private static func firstMatch(_ s: String, _ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { idx in
            let r = m.range(at: idx)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    // MARK: - properties

    private static func tokenizeProperties(_ line: String) -> [HLToken] {
        var out: [HLToken] = []
        let (lead, t) = splitLeading(line)
        push(&out, lead)
        if t.hasPrefix("#") || t.hasPrefix("!") {
            push(&out, t, .comment)
            return out
        }
        guard let eqIdx = t.firstIndex(where: { $0 == "=" || $0 == ":" }) else {
            push(&out, t)
            return out
        }
        push(&out, String(t[t.startIndex..<eqIdx]), .key)
        push(&out, String(t[eqIdx]))
        push(&out, String(t[t.index(after: eqIdx)...]))
        return out
    }

    // MARK: - yaml

    private static func tokenizeYaml(_ line: String) -> [HLToken] {
        var out: [HLToken] = []
        let (lead, t) = splitLeading(line)
        push(&out, lead)
        if t.hasPrefix("#") {
            push(&out, t, .comment)
            return out
        }
        var rest = t
        if rest.hasPrefix("- ") {
            push(&out, "- ")
            rest = String(rest.dropFirst(2))
        }
        if let m = firstMatch(rest, #"^([A-Za-z0-9_.\-"']+)(\s*:\s*)(.*)$"#) {
            push(&out, m[1], .key)
            push(&out, m[2])
            tokenizeScalar(m[3], &out)
            return out
        }
        tokenizeScalar(rest, &out)
        return out
    }

    // MARK: - toml

    private static func tokenizeToml(_ line: String) -> [HLToken] {
        var out: [HLToken] = []
        let (lead, t) = splitLeading(line)
        push(&out, lead)
        if t.hasPrefix("#") {
            push(&out, t, .comment)
            return out
        }
        if matches(t.trimmingCharacters(in: .whitespaces), #"^\[.*\]$"#) {
            push(&out, t, .section)
            return out
        }
        if let m = firstMatch(t, #"^([A-Za-z0-9_.\-"']+)(\s*=\s*)(.*)$"#) {
            push(&out, m[1], .key)
            push(&out, m[2])
            tokenizeScalar(m[3], &out)
            return out
        }
        push(&out, t)
        return out
    }

    // MARK: - json
    // One JSON line at a time — good enough for pretty-printed config,
    // which is what OMNIServers and every plugin actually write.

    private static func tokenizeJson(_ line: String) -> [HLToken] {
        var out: [HLToken] = []
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                var j = i + 1
                while j < chars.count && chars[j] != "\"" {
                    if chars[j] == "\\" { j += 1 }
                    j += 1
                }
                j = min(j + 1, chars.count)
                let str = String(chars[i..<j])
                let restAfter = String(chars[j...]).drop { $0 == " " }
                let isKey = restAfter.first == ":"
                push(&out, str, isKey ? .key : .string)
                i = j
            } else if startsWith(chars, i, "true") || startsWith(chars, i, "false") || startsWith(chars, i, "null") {
                let kw = startsWith(chars, i, "false") ? "false" : startsWith(chars, i, "true") ? "true" : "null"
                push(&out, kw, .keyword)
                i += kw.count
            } else if c.isNumber || c == "-", i - 1 < 0 || isJsonBoundary(chars[i - 1]) {
                var j = i
                while j < chars.count, chars[j].isNumber || "eE+-.".contains(chars[j]) { j += 1 }
                push(&out, String(chars[i..<j]), .number)
                i = j
            } else {
                var j = i + 1
                // Real bug this port surfaced (present in the original
                // `highlightConfig.ts` too, fixed there alongside this):
                // this catch-all scan has to stop right before a
                // true/false/null keyword starts, or it swallows the
                // keyword as plain text before the dedicated branch
                // above ever gets a turn at that position — e.g.
                // `"a": true,` never highlighted `true` at all.
                while j < chars.count, chars[j] != "\"", !(chars[j].isNumber || chars[j] == "-"),
                      !startsWith(chars, j, "true"), !startsWith(chars, j, "false"), !startsWith(chars, j, "null") {
                    j += 1
                }
                push(&out, String(chars[i..<j]))
                i = j
            }
        }
        return out
    }

    private static func startsWith(_ chars: [Character], _ i: Int, _ s: String) -> Bool {
        let sChars = Array(s)
        guard i + sChars.count <= chars.count else { return false }
        return Array(chars[i..<(i + sChars.count)]) == sChars
    }

    private static func isJsonBoundary(_ c: Character) -> Bool {
        c == " " || c == "," || c == ":" || c == "[" || c == "{"
    }
}
