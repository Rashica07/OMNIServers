import SwiftUI

/// "Message players" — a full-screen announcement, a chat broadcast, or a
/// private warning to one player, all sent live over RCON. Direct port
/// of `BroadcastSection.tsx`. No dedicated Rust backend — this composes
/// vanilla `/title`/`/tellraw` JSON-text commands client-side and sends
/// them through the same `RconService.run` every other command uses.
struct BroadcastCard: View {
    let server: ServerRecord
    let reachable: Bool

    private enum Mode: String, CaseIterable { case screen, chat, warn
        var label: String {
            switch self { case .screen: "Full screen"; case .chat: "Chat"; case .warn: "Warn one" }
        }
        var symbol: String {
            switch self { case .screen: "tv"; case .chat: "bubble.left.and.bubble.right"; case .warn: "exclamationmark.triangle" }
        }
    }

    @State private var mode: Mode = .chat
    @State private var busy = false
    @State private var error: String?
    @State private var note: String?
    @State private var players: [String] = []

    @State private var bigText = ""
    @State private var smallText = ""
    @State private var screenColor = "yellow"

    @State private var chatText = ""
    @State private var chatColor = "white"
    @State private var tagged = true

    @State private var warnTarget = ""
    @State private var warnText = ""

    var body: some View {
        SettingsCard(title: "Message players", symbol: "bubble.left.and.exclamationmark.bubble.right",
                     description: "A full-screen announcement, a chat broadcast, or a private warning to one player — all sent live over RCON.") {
            CPSegmentedPicker(selection: $mode, options: Mode.allCases.map { ($0, $0.label, $0.symbol) })

            if !reachable {
                Label("Start the server and set up RCON above to send messages to players.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(CPColor.inkFaint)
            } else {
                switch mode {
                case .screen: screenBody
                case .chat: chatBody
                case .warn: warnBody
                }
            }

            if let note { Text(note).font(.caption2).foregroundStyle(CPColor.ok) }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(CPColor.warn)
            }
        }
        .task(id: "\(server.id)-\(reachable)") { await loadPlayers() }
    }

    // MARK: - Screen mode

    private var screenBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            screenPreview
            TextField("Big message — e.g. Restarting in 5 minutes", text: $bigText)
                .textFieldStyle(.roundedBorder)
            TextField("Small message underneath (optional)", text: $smallText)
                .textFieldStyle(.roundedBorder)
            HStack {
                colorPicker($screenColor)
                Spacer()
                Button(busy ? "Sending…" : "Show on everyone's screen") { Task { await sendScreen() } }
                    .cpButton(.primary)
                    .disabled(busy || bigText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var screenPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(CPColor.console)
            VStack(spacing: 4) {
                Text(bigText.isEmpty ? "Big message" : bigText)
                    .font(CPFont.display(20, weight: .medium))
                    .foregroundStyle(MessageColors.colors[screenColor] ?? .white)
                    .lineLimit(1)
                if !smallText.isEmpty {
                    Text(smallText).font(.caption).foregroundStyle(CPColor.inkDim)
                }
            }
            .padding()
        }
        .frame(height: 90)
    }

    // MARK: - Chat mode

    private var chatBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Message everyone in chat…", text: $chatText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await sendChat() } }
            HStack {
                colorPicker($chatColor)
                Toggle("\"[Server]\" tag", isOn: $tagged).toggleStyle(.checkbox).font(.caption2)
                Spacer()
                Button(busy ? "Sending…" : "Send to everyone") { Task { await sendChat() } }
                    .cpButton(.primary)
                    .disabled(busy || chatText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: - Warn mode

    private var warnBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            if players.isEmpty {
                Label("Nobody's online right now.", systemImage: "person.2")
                    .font(.caption).foregroundStyle(CPColor.inkFaint)
            } else {
                Picker("Player", selection: $warnTarget) {
                    Text("Choose a player…").tag("")
                    ForEach(players, id: \.self) { Text($0).tag($0) }
                }
                TextField("Only this player will see it…", text: $warnText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await sendWarn() } }
                HStack {
                    Label("Private — only \(warnTarget.isEmpty ? "the chosen player" : warnTarget) sees this", systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(CPColor.warn)
                    Spacer()
                    Button(busy ? "Sending…" : "Send private warning") { Task { await sendWarn() } }
                        .cpButton(.primary)
                        .disabled(busy || warnTarget.isEmpty || warnText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func colorPicker(_ selection: Binding<String>) -> some View {
        HStack(spacing: 2) {
            ForEach(MessageColors.names, id: \.self) { name in
                Button {
                    selection.wrappedValue = name
                } label: {
                    Circle()
                        .fill(MessageColors.colors[name] ?? .white)
                        .frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(selection.wrappedValue == name ? CPColor.accent : .clear, lineWidth: 2))
                        .padding(5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(name.replacingOccurrences(of: "_", with: " "))
            }
        }
    }

    // MARK: - Actions

    private func loadPlayers() async {
        guard reachable else { return }
        if let result = try? await RconService.shared.players(record: server) {
            players = result.players
        }
    }

    private func tellraw(_ target: String, _ parts: [[String: Any]]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: parts))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return "tellraw \(target) \(json)"
    }

    private func title(_ target: String, _ kind: String, _ part: [String: Any]) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: part))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "title \(target) \(kind) \(json)"
    }

    private func send(_ commands: [String], ok: String) async {
        busy = true; error = nil; note = nil
        defer { busy = false }
        do {
            for cmd in commands {
                _ = try await RconService.shared.run(record: server, command: cmd)
            }
            note = ok
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func sendScreen() async {
        var cmds = ["title @a times 10 70 20", title("@a", "title", ["text": bigText, "color": screenColor, "bold": true])]
        if !smallText.trimmingCharacters(in: .whitespaces).isEmpty {
            cmds.append(title("@a", "subtitle", ["text": smallText, "color": "gray"]))
        }
        await send(cmds, ok: "Sent to every screen.")
        bigText = ""; smallText = ""
    }

    private func sendChat() async {
        let parts: [[String: Any]] = tagged
            ? [["text": "[Server] ", "color": "gold", "bold": true], ["text": chatText, "color": chatColor]]
            : [["text": chatText, "color": chatColor]]
        await send([tellraw("@a", parts)], ok: "Sent to everyone.")
        chatText = ""
    }

    private func sendWarn() async {
        let parts: [[String: Any]] = [
            ["text": "⚠ Warning — ", "color": "red", "bold": true],
            ["text": warnText, "color": "yellow"],
        ]
        await send([tellraw(warnTarget, parts)], ok: "Sent privately to \(warnTarget).")
        warnText = ""
    }
}

/// Minecraft's named chat colours — a different palette from the §-code
/// swatches `BrandingCard`/`MOTDPreview` uses for the MOTD, same swatch idea.
enum MessageColors {
    static let names = ["white", "yellow", "gold", "red", "light_purple", "aqua", "green", "gray"]
    static let colors: [String: Color] = [
        "white": Color(hex: 0xFFFFFF), "yellow": Color(hex: 0xFFFF55), "gold": Color(hex: 0xFFAA00),
        "red": Color(hex: 0xFF5555), "light_purple": Color(hex: 0xFF55FF), "aqua": Color(hex: 0x55FFFF),
        "green": Color(hex: 0x55FF55), "gray": Color(hex: 0xAAAAAA),
    ]
}
