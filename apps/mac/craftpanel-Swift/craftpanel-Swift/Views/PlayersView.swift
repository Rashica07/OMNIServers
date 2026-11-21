import SwiftUI

/// Ops / whitelist / bans / online players / messaging / security. Direct
/// UI counterpart of the Tauri app's Players tab (`RconPanel` +
/// `BroadcastSection` + `AdminPanel` + `SecuritySection`), laid out as
/// icon+title+description cards (`SettingsCard`) to match that tab's
/// visual language — same reasoning as the Settings screen's redesign.
///
/// Not yet ported: `PlayerActivityChart`/`ServerMetricsHistory` (needs
/// `metrics_history.rs`'s background sampler — a real gap, Batch H
/// territory) and `PlayerHistory`'s join/leave log (`analytics.rs`).
///
/// Every add-row here is the standalone `AddRow` struct below, not a
/// closure-captured inline view builder — worth calling out because the
/// exact real bug this project hit on the Tauri side (a nested component
/// definition capturing local state, so React gave it a fresh identity
/// every render and the whole field remounted on each keystroke) has a
/// SwiftUI-shaped equivalent to avoid: view identity here comes from
/// each row being an actual top-level `View` type with real `@Binding`s,
/// not a `@ViewBuilder` closure that closes over `@State` from outside.
struct PlayersView: View {
    let record: ServerRecord
    @Environment(ProcessManager.self) private var processes

    @State private var lists: AdminLists?
    @State private var online: (online: Int, max: Int, players: [String])?
    @State private var rconSettings: RconSettingsInfo?
    @State private var loadError: String?
    @State private var busy = false
    @State private var settingUpRcon = false

    @State private var newOp = ""
    @State private var newWhitelist = ""
    @State private var newBan = ""
    @State private var newBanReason = ""
    @State private var rawCommand = ""
    @State private var rawCommandOutput: String?

    private var isRunning: Bool {
        processes.isRunning(record.id)
    }

    private var reachable: Bool {
        isRunning && (rconSettings?.enabled ?? false)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let loadError {
                    Label(loadError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(CPColor.warn)
                        .font(.callout)
                }

                HStack {
                    Spacer()
                    Button { Task { await refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .cpButton(.secondary, size: .sm)
                        .disabled(busy)
                }
                rconCard
                BroadcastCard(server: record, reachable: reachable)
                adminCard
                PlayerActivityCard(server: record)
                ServerMetricsHistoryCard(server: record)
                PlayerHistoryCard(server: record)
                SecurityCard(server: record)
            }
            .padding(16)
        }
        .background(CPColor.bg)
        .navigationTitle("Players")
        .task(id: record.id) {
            await refresh()
        }
    }

    // MARK: - RCON / online

    private var rconCard: some View {
        SettingsCard(title: "Remote console", symbol: "antenna.radiowaves.left.and.right",
                     description: "Who's online right now, and live player management.") {
            if !isRunning {
                Text("Start the server to manage players live. Ops, whitelist, and bans still show below.")
                    .font(.callout)
                    .foregroundStyle(CPColor.inkFaint)
            } else if let rconSettings, !rconSettings.enabled {
                VStack(alignment: .leading, spacing: 8) {
                    Label("RCON isn't set up for this server yet.", systemImage: "network.slash")
                        .font(.callout.weight(.medium))
                    Text("Setting it up enables live player management here. It only ever writes RCON-related keys.")
                        .font(.caption)
                        .foregroundStyle(CPColor.inkFaint)
                    Button(settingUpRcon ? "Setting up…" : "Set Up RCON") {
                        Task { await setupRcon() }
                    }
                    .cpButton(.primary)
                    .disabled(settingUpRcon)
                }
            } else {
                if let online {
                    Text("\(online.online) of \(online.max) players online")
                        .font(.caption)
                        .foregroundStyle(CPColor.inkFaint)
                    ForEach(online.players, id: \.self) { name in
                        HStack {
                            Text(name)
                            Spacer()
                            Button("Kick") {
                                Task { await act(action: "kick", player: name) {} }
                            }
                            .disabled(busy)
                        }
                    }
                    if online.players.isEmpty {
                        Text("Nobody's online right now.")
                            .font(.caption)
                            .foregroundStyle(CPColor.inkFaint)
                    }
                } else {
                    ProgressView()
                }
            }
        }
    }

    // MARK: - Admin (ops / whitelist / bans / raw command)

    private var adminCard: some View {
        SettingsCard(title: "Ops, whitelist & bans", symbol: "person.2.badge.gearshape",
                     description: "Manage access lists and run raw commands.") {
            Text("OPS").font(.caption2).foregroundStyle(CPColor.inkFaint)
            listRows(lists?.ops ?? [], removeAction: "deop")
            AddRow(text: $newOp, placeholder: "Player name", buttonLabel: "Op", disabled: !isRunning || busy) {
                await act(action: "op", player: newOp) { newOp = "" }
            }

            Rectangle().fill(CPColor.lineSoft).frame(height: 1)

            Text("WHITELIST").font(.caption2).foregroundStyle(CPColor.inkFaint)
            if let lists {
                HStack(spacing: 6) {
                    Label(lists.whitelistOn ? "Whitelist is on" : "Whitelist is off", systemImage: lists.whitelistOn ? "checkmark.shield" : "shield.slash")
                    if lists.enforceWhitelist {
                        Text("(enforced)").foregroundStyle(CPColor.inkFaint)
                    }
                }
                .font(.caption2)
                .foregroundStyle(CPColor.inkFaint)
            }
            listRows(lists?.whitelist ?? [], removeAction: "whitelist-remove")
            AddRow(text: $newWhitelist, placeholder: "Player name", buttonLabel: "Add", disabled: !isRunning || busy) {
                await act(action: "whitelist-add", player: newWhitelist) { newWhitelist = "" }
            }

            Rectangle().fill(CPColor.lineSoft).frame(height: 1)

            Text("BANNED PLAYERS").font(.caption2).foregroundStyle(CPColor.inkFaint)
            ForEach(lists?.banned ?? []) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                        if let reason = entry.reason {
                            Text(reason).font(.caption2).foregroundStyle(CPColor.inkFaint)
                        }
                    }
                    Spacer()
                    if isRunning {
                        Button("Pardon") {
                            Task { await act(action: "pardon", player: entry.name) {} }
                        }
                        .disabled(busy)
                    }
                }
            }
            TextField("Reason (optional)", text: $newBanReason)
                .font(.caption)
                .textFieldStyle(.roundedBorder)
                .disabled(!isRunning || busy)
            AddRow(text: $newBan, placeholder: "Player name", buttonLabel: "Ban", disabled: !isRunning || busy) {
                let reason = newBanReason
                await act(action: "ban", player: newBan, arg: reason.isEmpty ? nil : reason) {
                    newBan = ""; newBanReason = ""
                }
            }

            if let lists, !lists.bannedIPs.isEmpty {
                Rectangle().fill(CPColor.lineSoft).frame(height: 1)
                Text("BANNED IPs").font(.caption2).foregroundStyle(CPColor.inkFaint)
                ForEach(lists.bannedIPs, id: \.self) { ip in
                    Text(ip).font(.system(.caption, design: .monospaced))
                }
            }

            Rectangle().fill(CPColor.lineSoft).frame(height: 1)

            Text("RUN A COMMAND").font(.caption2).foregroundStyle(CPColor.inkFaint)
            HStack {
                TextField("/say hello", text: $rawCommand)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .disabled(!isRunning || busy)
                    .onSubmit { Task { await runRaw() } }
                Button("Run") { Task { await runRaw() } }
                    .disabled(!isRunning || busy || rawCommand.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let rawCommandOutput, !rawCommandOutput.isEmpty {
                Text(rawCommandOutput)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(CPColor.inkFaint)
                    .textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func listRows(_ names: [String], removeAction: String) -> some View {
        ForEach(names, id: \.self) { name in
            HStack {
                Text(name)
                Spacer()
                if isRunning {
                    Button("Remove") {
                        Task { await act(action: removeAction, player: name) {} }
                    }
                    .disabled(busy)
                }
            }
        }
        if names.isEmpty {
            Text("None yet.").font(.caption2).foregroundStyle(CPColor.inkFaint)
        }
    }

    // MARK: - Actions

    private func refresh() async {
        lists = AdminLists.read(serverDir: record.path)
        rconSettings = await RconService.shared.settings(for: record)
        if isRunning, rconSettings?.enabled == true {
            online = try? await RconService.shared.players(record: record)
        } else {
            online = nil
        }
        loadError = nil
    }

    private func act(action: String, player: String, arg: String? = nil, onSuccess: () -> Void) async {
        guard !player.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await RconService.shared.playerAction(record: record, action: action, player: player, arg: arg)
            onSuccess()
            await refresh()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func runRaw() async {
        let cmd = rawCommand.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            rawCommandOutput = try await RconService.shared.run(record: record, command: cmd)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func setupRcon() async {
        settingUpRcon = true
        defer { settingUpRcon = false }
        do {
            let result = try await RconService.shared.setup(for: record, isRunning: isRunning)
            if result.restartRequired {
                loadError = "RCON is set up (port \(result.port)). Restart the server for it to take effect."
            } else {
                loadError = nil
            }
            await refresh()
        } catch {
            loadError = error.localizedDescription
        }
    }
}

/// A single "text field + action button" row, its own top-level `View`
/// type rather than an inline closure — see the doc comment on
/// `PlayersView` for why that distinction matters here.
private struct AddRow: View {
    @Binding var text: String
    let placeholder: String
    let buttonLabel: String
    let disabled: Bool
    let action: () async -> Void

    var body: some View {
        HStack {
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .disabled(disabled)
                .onSubmit { Task { await action() } }
            Button(buttonLabel) {
                Task { await action() }
            }
            .disabled(disabled || text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
