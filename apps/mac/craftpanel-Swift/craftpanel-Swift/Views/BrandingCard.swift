import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// "How it looks in the server list" — MOTD editor (with a §-color-code
/// swatch palette and a live preview) plus the 64×64 server icon
/// (preview/set/change/remove). Direct port of `BrandingSection.tsx`,
/// backed by `Properties` (MOTD is a plain `server.properties` key) and
/// `BrandingManager` (the icon file).
///
/// **Native win**: icon picking uses `NSOpenPanel` directly instead of a
/// dialog plugin — one less moving part, and it's already how
/// `AddServerSheet`/`FilesView` pick files in this app.
struct BrandingCard: View {
    let server: ServerRecord

    @State private var motd: String = ""
    @State private var saved: String = ""
    @State private var hasIcon = false
    @State private var busy = false
    @State private var errorText: String?
    @State private var note: String?

    private var root: URL { URL(fileURLWithPath: server.path) }
    private var dirty: Bool { motd != saved }

    var body: some View {
        SettingsCard(title: "How it looks in the server list", symbol: "text.below.photo",
                     description: "The description and icon your friends see before they join.") {
            preview

            TextEditor(text: Binding(
                get: { motd },
                set: { motd = String($0.split(separator: "\n", omittingEmptySubsequences: false).prefix(2).joined(separator: "\n")) }
            ))
            .font(.system(.caption, design: .monospaced))
            .frame(height: 40)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(CPColor.surface2)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(CPColor.line))

            swatches

            HStack(spacing: 8) {
                Button(busy ? "Saving…" : "Save MOTD") {
                    Task { await saveMOTD() }
                }
                .cpButton(.primary)
                .disabled(busy || !dirty)

                Button(hasIcon ? "Change icon…" : "Set icon…") { pickIcon() }
                    .disabled(busy)
                if hasIcon {
                    Button("Remove icon") { Task { await removeIcon() } }
                        .disabled(busy)
                }
                if let note {
                    Text(note).font(.caption2).foregroundStyle(CPColor.inkFaint)
                }
            }

            Text("Restart the server for MOTD/icon changes to show in the multiplayer list.")
                .font(.caption2)
                .foregroundStyle(CPColor.inkFaint)

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(CPColor.warn)
            }
        }
        .task(id: server.id) { reload() }
    }

    private var preview: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(CPColor.console)
                if hasIcon, let img = NSImage(contentsOf: root.appendingPathComponent(BrandingManager.iconFile)) {
                    Image(nsImage: img).resizable().frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Text("no icon").font(.system(size: 9)).foregroundStyle(CPColor.inkFaint)
                }
            }
            .frame(width: 64, height: 64)

            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(MOTDPreview.parse(motd).enumerated()), id: \.offset) { _, spans in
                    HStack(spacing: 0) {
                        ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                            Text(span.text.isEmpty ? " " : span.text)
                                .font(.system(size: 12, weight: span.bold ? .bold : .regular, design: .monospaced))
                                .italic(span.italic)
                                .underline(span.underline)
                                .foregroundStyle(span.color)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(CPColor.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var swatches: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                ForEach(MOTDPreview.colorCodes, id: \.self) { code in
                    Button {
                        motd += "\u{00A7}\(code)"
                    } label: {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(MOTDPreview.colors[code] ?? .white)
                            .frame(width: 14, height: 14)
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(.black.opacity(0.3)))
                            .padding(5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("§\(code)")
                }
                ForEach(["l", "o", "n", "r"], id: \.self) { code in
                    Button("§\(code)") { motd += "\u{00A7}\(code)" }
                        .buttonStyle(.plain)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(CPColor.inkFaint)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(CPColor.line))
                }
            }
        }
    }

    private func reload() {
        let props = Properties.load(dir: root)
        motd = props.getOr("motd", "")
        saved = motd
        hasIcon = BrandingManager.hasIcon(serverDir: root)
    }

    private func saveMOTD() async {
        busy = true; errorText = nil; note = nil
        defer { busy = false }
        do {
            var props = Properties.load(dir: root)
            props.set("motd", motd)
            try props.save()
            saved = motd
            note = "MOTD saved."
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func pickIcon() {
        let panel = NSOpenPanel()
        panel.title = "Choose a server icon (PNG/JPG)"
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            busy = true; errorText = nil; note = nil
            defer { busy = false }
            do {
                try BrandingManager.setIcon(serverDir: root, source: url)
                hasIcon = true
                note = "Icon set (64×64)."
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func removeIcon() async {
        busy = true; errorText = nil; note = nil
        defer { busy = false }
        do {
            try BrandingManager.clearIcon(serverDir: root)
            hasIcon = false
            note = "Icon removed."
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// MOTD `§`/`&`-color-code parsing for the live preview. Direct port of
/// `BrandingSection.tsx`'s `parseMotd`.
enum MOTDPreview {
    struct Span { var text: String; var color: Color; var bold: Bool; var italic: Bool; var underline: Bool }

    static let colorCodes = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
    static let colors: [String: Color] = [
        "0": Color(hex: 0x000000), "1": Color(hex: 0x0000AA), "2": Color(hex: 0x00AA00), "3": Color(hex: 0x00AAAA),
        "4": Color(hex: 0xAA0000), "5": Color(hex: 0xAA00AA), "6": Color(hex: 0xFFAA00), "7": Color(hex: 0xAAAAAA),
        "8": Color(hex: 0x555555), "9": Color(hex: 0x5555FF), "a": Color(hex: 0x55FF55), "b": Color(hex: 0x55FFFF),
        "c": Color(hex: 0xFF5555), "d": Color(hex: 0xFF55FF), "e": Color(hex: 0xFFFF55), "f": Color(hex: 0xFFFFFF),
    ]

    static func parse(_ raw: String) -> [[Span]] {
        raw.split(separator: "\n", omittingEmptySubsequences: false).map { line -> [Span] in
            var spans: [Span] = []
            var cur = Span(text: "", color: .white, bold: false, italic: false, underline: false)
            let chars = Array(line)
            var i = 0
            while i < chars.count {
                let ch = chars[i]
                if (ch == "\u{00A7}" || ch == "&"), i + 1 < chars.count {
                    let code = String(chars[i + 1]).lowercased()
                    i += 2
                    if !cur.text.isEmpty { spans.append(cur) }
                    if let c = colors[code] {
                        cur = Span(text: "", color: c, bold: false, italic: false, underline: false)
                    } else {
                        cur.text = ""
                        switch code {
                        case "l": cur.bold = true
                        case "o": cur.italic = true
                        case "n": cur.underline = true
                        case "r": cur = Span(text: "", color: .white, bold: false, italic: false, underline: false)
                        default: break
                        }
                    }
                    continue
                }
                cur.text.append(ch)
                i += 1
            }
            if !cur.text.isEmpty { spans.append(cur) }
            return spans.isEmpty ? [cur] : spans
        }
    }
}
