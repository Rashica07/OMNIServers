import SwiftUI

/// Turns a raw Minecraft console line into a styled `AttributedString`:
/// the timestamp/thread prefix dimmed, the severity coloured, the message
/// left plain and readable.
///
/// A native win over the Tauri app, which renders console output as flat
/// monospace text — `AttributedString` gets real per-run styling with no
/// HTML/CSS layer and no per-line DOM nodes. Deliberately regex-free and
/// allocation-light: this runs on every one of up to 500 buffered lines
/// on every console re-render.
enum ConsoleLineStyle {

    enum Severity: Equatable {
        case info, warn, error, system

        var color: Color {
            switch self {
            case .info: CPColor.inkFaint
            case .warn: CPColor.warn
            case .error: CPColor.bad
            // `text-accent-soft` in `ConsoleView.tsx`'s own `LEVEL_TEXT`
            // map, not the stronger base `accent` — that's the
            // fill/button shade, this is the text-on-dark shade.
            case .system: CPColor.accentSoft
            }
        }
    }

    /// Vanilla/Paper/Fabric all log as `[12:34:56] [Server thread/INFO]: msg`.
    /// Bedrock uses `[2026-09-02 12:34:56:789 INFO] msg`. Both are handled
    /// by looking for the severity word rather than trying to parse the
    /// whole prefix shape — far more robust across server flavours than a
    /// strict format match would be.
    static func severity(of text: String, stream: LogLine.Stream) -> Severity {
        if stream == .system { return .system }
        let upper = text.uppercased()
        if upper.contains("/ERROR") || upper.contains(" ERROR]") || upper.contains("/FATAL") || upper.contains("SEVERE") {
            return .error
        }
        if upper.contains("/WARN") || upper.contains(" WARN]") {
            return .warn
        }
        // stderr with no explicit level is still worth flagging — most
        // JVM stack traces arrive this way, with no [ERROR] tag at all.
        if stream == .stderr { return .error }
        return .info
    }

    static func attributed(_ line: LogLine) -> AttributedString {
        let sev = severity(of: line.text, stream: line.stream)

        if line.stream == .system {
            var s = AttributedString(line.text)
            s.foregroundColor = sev.color
            s.font = .system(.caption, design: .monospaced).italic()
            return s
        }

        var result = AttributedString()

        // Split the leading bracketed prefix(es) from the message so the
        // timestamp/thread noise can recede and the message can lead.
        let (prefix, message) = splitPrefix(line.text)

        if !prefix.isEmpty {
            var p = AttributedString(prefix)
            p.foregroundColor = sev == .info ? CPColor.inkFaint.opacity(0.6) : sev.color.opacity(0.8)
            p.font = .system(.caption, design: .monospaced)
            result.append(p)
        }

        var m = AttributedString(message)
        m.font = .system(.caption, design: .monospaced)
        m.foregroundColor = switch sev {
        case .info: CPColor.ink
        case .warn: CPColor.warn
        case .error: CPColor.bad
        case .system: CPColor.accentSoft // unreachable here (system lines return earlier above), kept in sync anyway
        }
        result.append(m)

        return result
    }

    /// Returns (leading bracketed prefix incl. trailing separator, remainder).
    /// Handles both `[..] [..]: msg` and `[..] msg`; returns an empty
    /// prefix for anything that doesn't start with `[`, so unrecognized
    /// lines simply render plain rather than being mangled.
    static func splitPrefix(_ text: String) -> (String, String) {
        guard text.first == "[" else { return ("", text) }
        var idx = text.startIndex
        var lastClose: String.Index?
        var depth = 0
        while idx < text.endIndex {
            let c = text[idx]
            if c == "[" {
                depth += 1
            } else if c == "]" {
                depth -= 1
                if depth == 0 { lastClose = idx }
            } else if depth == 0, c != " ", c != ":" {
                // first non-bracket, non-separator char ends the prefix run
                break
            }
            idx = text.index(after: idx)
        }
        guard let close = lastClose else { return ("", text) }
        var end = text.index(after: close)
        // absorb a trailing ": " or " " so the message starts cleanly
        while end < text.endIndex, text[end] == ":" || text[end] == " " {
            end = text.index(after: end)
        }
        return (String(text[text.startIndex..<end]), String(text[end...]))
    }
}
