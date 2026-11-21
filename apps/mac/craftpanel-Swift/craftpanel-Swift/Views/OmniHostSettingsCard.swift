import SwiftUI

/// OMNIHost keeps its settings in `pumpkin.toml`, not `server.properties`, so it gets its own card.
/// The engine reads the file at start, so changes need the server stopped.
struct OmniHostSettingsCard: View {
    let server: ServerRecord
    let isRunning: Bool

    @State private var draft = PumpkinConfig.Editable(onlineMode: true, motd: "", maxPlayers: 20, gamemode: "survival", difficulty: "normal")
    @State private var saved: PumpkinConfig.Editable?
    @State private var note: String?
    @State private var errorText: String?

    private var dir: URL { URL(fileURLWithPath: server.path) }
    private var dirty: Bool { saved != nil && saved != draft }

    var body: some View {
        SettingsCard(title: "OMNIHost", symbol: "bolt.fill",
                     description: "Settings for this server. Saved to pumpkin.toml and used the next time it starts.") {
            if saved == nil {
                Text("No settings file yet. Start the server once to create it.")
                    .font(.callout).foregroundStyle(CPColor.inkFaint)
            } else {
                Toggle("Online mode (Mojang sign-in)", isOn: $draft.onlineMode).disabled(isRunning)
                if !draft.onlineMode {
                    Label("Offline mode: anyone can join with any name, including as an operator's name. Use it only with people you trust.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(CPColor.warn)
                }
                HStack(spacing: 12) {
                    CPField(label: "Gamemode") {
                        Picker("", selection: $draft.gamemode) {
                            ForEach(["survival", "creative", "adventure", "spectator"], id: \.self) { Text($0.capitalized) }
                        }.labelsHidden().disabled(isRunning)
                    }
                    CPField(label: "Difficulty") {
                        Picker("", selection: $draft.difficulty) {
                            ForEach(["peaceful", "easy", "normal", "hard"], id: \.self) { Text($0.capitalized) }
                        }.labelsHidden().disabled(isRunning)
                    }
                    CPField(label: "Max players") {
                        Stepper("\(draft.maxPlayers)", value: $draft.maxPlayers, in: 1...1000).disabled(isRunning)
                    }
                }
                CPField(label: "Message of the day", hint: "Shown in your friends' server list") {
                    TextField("A Minecraft Server", text: $draft.motd).textFieldStyle(.roundedBorder).disabled(isRunning)
                }
                HStack {
                    Button("Save") { save() }.cpButton(.primary, size: .sm).disabled(isRunning || !dirty)
                    if isRunning { Text("Stop the server to change these.").font(.caption).foregroundStyle(CPColor.inkFaint) }
                    else if let note { Text(note).font(.caption).foregroundStyle(CPColor.ok) }
                }
                if let errorText { Text(errorText).font(.caption).foregroundStyle(CPColor.warn) }
            }
        }
        .task(id: server.id) { load() }
    }

    private func load() {
        let e = PumpkinConfig.read(serverDir: dir)
        saved = e
        if let e { draft = e }
        note = nil; errorText = nil
    }

    private func save() {
        do {
            try PumpkinConfig.apply(draft, serverDir: dir)
            saved = draft
            note = "Saved. Applies on the next start."
            errorText = nil
        } catch {
            errorText = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
