import SwiftUI
import SwiftData

/// Server settings: OMNIServers's own launch config (name, Java, RAM), the
/// real server.properties editor, MOTD/icon branding, and per-server
/// automation — the direct UI counterpart of the Tauri app's Settings
/// tab, laid out as icon+title+description cards (`SettingsCard`) rather
/// than flat `Form` `Section`s, matching that tab's actual visual
/// language instead of just its field list.
struct SettingsView: View {
    let server: ServerRecord
    @Environment(ProcessManager.self) private var processes
    @Environment(\.modelContext) private var modelContext
    var onRemoved: () -> Void = {}

    @State private var settings: ServerSettingsResult?
    @State private var edited: [String: String] = [:]
    @State private var saving = false
    @State private var errorText: String?
    @State private var savedFlash = false
    @State private var showingRemoveConfirm = false
    @State private var lowSpecMode = "Small survival server"
    @State private var lowSpecPlayers = 2
    @State private var lowSpecStatus: String?
    @State private var showTransfer = false

    private var isRunning: Bool {
        processes.isRunning(server.id)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                launchCard
                if OmniHostTransfer.canTransfer(server.serverType) {
                    SettingsCard(title: "Move to OMNIHost", symbol: "bolt.fill",
                                 description: "Copy this server's world and settings to a fast native OMNIHost server. This server stays as it is.") {
                        Button("Move to OMNIHost…") { showTransfer = true }.cpButton(.secondary, size: .sm)
                    }
                }
                if server.serverType.isOmniHost { OmniHostSettingsCard(server: server, isRunning: isRunning) }
                BrandingCard(server: server)
                AutomationCard(server: server)
                if !server.serverType.isBedrock && !server.serverType.isOmniHost {
                    JvmArgsCard(server: server)
                    ManagementAPICard(server: server)
                }
                PluginConfigSection(server: server)
                if !server.serverType.isBedrock && !server.serverType.isOmniHost { lowSpecCard }
                if server.serverType.isOmniHost {
                    // OMNIHost keeps its settings in pumpkin.toml (card above), not server.properties.
                    EmptyView()
                } else if let settings, settings.present {
                    propertiesCard("Common", symbol: "slider.horizontal.3", fields: settings.common)
                    propertiesCard("Advanced", symbol: "wrench.and.screwdriver", fields: settings.advanced)
                    // Expert mode (App Settings → General): every key, raw — Tauri's "raw" view.
                    if AppDefaults.expertMode { rawPropertiesCard(settings.all) }
                } else if let settings, !settings.present {
                    SettingsCard(title: "server.properties", symbol: "doc.badge.exclamationmark") {
                        Text("No server.properties yet — start the server once to generate it.")
                            .font(.callout)
                            .foregroundStyle(CPColor.inkFaint)
                    }
                } else {
                    ProgressView().padding(20).frame(maxWidth: .infinity)
                }

                onDiskCard
                removeServerCard

                if let errorText {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(CPColor.warn)
                        .font(.callout)
                }
            }
            .padding(16)
        }
        .background(CPColor.bg)
        .navigationTitle(server.name)
        .sheet(isPresented: $showTransfer) { TransferToOmniHostSheet(server: server) }
        .alert("Remove \(server.name)?", isPresented: $showingRemoveConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { removeServer() }
        } message: {
            Text("Takes it out of OMNIServers's list. Your world and files stay exactly where they are on disk.")
        }
        .toolbar {
            ToolbarItem {
                if savedFlash {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(CPColor.ok)
                        .font(.callout)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !edited.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(CPColor.warn)
                    Text("You have unsaved changes").font(.callout).foregroundStyle(CPColor.ink)
                    Spacer()
                    Button("Discard") { edited = [:]; Toasts.shared.show("Changes discarded", symbol: "arrow.uturn.backward.circle.fill") }.cpButton(.secondary, size: .sm).disabled(saving)
                    Button(saving ? "Saving…" : "Save changes") { Task { await apply() } }
                        .cpButton(.primary, size: .sm).disabled(saving)
                        .keyboardShortcut("s", modifiers: .command)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(CPColor.surface)
                .overlay(alignment: .top) { Rectangle().fill(CPColor.lineSoft).frame(height: 1) }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: edited.isEmpty)
        .task(id: server.id) {
            reload()
        }
    }

    // MARK: - Launch config (OMNIServers's own record, not server.properties)

    private var launchCard: some View {
        SettingsCard(title: "Launch", symbol: "bolt.fill", description: "How OMNIServers starts this server.") {
            LabeledContent("Type", value: server.serverType.label)
            if let v = server.mcVersion {
                LabeledContent("Minecraft version", value: v)
            }
            LabeledContent("Launch target", value: server.launchTarget)
                .font(.system(.caption, design: .monospaced))
            LabeledContent("Path", value: server.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            if !server.serverType.isBedrock && !server.serverType.isOmniHost {
                LabeledContent("Java path") {
                    TextField("", text: Binding(
                        get: { server.javaPath },
                        set: { server.javaPath = $0 }
                    ))
                    .font(.system(.body, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .disabled(isRunning)
                }
            }

            if !server.serverType.isBedrock && !server.serverType.isOmniHost {
                RamPicker(ramMB: Binding(get: { Double(server.ramMB) }, set: { server.ramMB = UInt32($0) }),
                          kind: RamAdvisor.Kind(serverType: server.serverType), followsInitially: false,
                          disabled: isRunning)
                    .padding(.vertical, 4)
            }

            if isRunning {
                Text("Stop the server to change Java path or memory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var lowSpecCard: some View {
        let kind: RamAdvisor.Kind = lowSpecMode == "Skyblock / mini-game" ? .minigame
            : lowSpecMode == "Modded" ? .modded : .vanillaLike
        let system = SystemMemory.current()
        let recommended = RamAdvisor.recommend(kind: kind, players: lowSpecPlayers, safeMaxMB: system.safeMaxMB)
        return SettingsCard(title: "Low-spec server preset", symbol: "speedometer",
                            description: "Lowers the chunk distances that use the most memory and CPU, then sets a sensible memory limit for your Mac. Applied while the server is stopped.") {
            Picker("Server type", selection: $lowSpecMode) {
                ForEach(["Small survival server", "Skyblock / mini-game", "Modded"], id: \.self) { Text($0).tag($0) }
            }
            Stepper("About \(lowSpecPlayers) players", value: $lowSpecPlayers, in: 1...50)
            LabeledContent("Suggested memory", value: SystemRAM.format(mb: recommended))
            LabeledContent("Mac safe limit", value: SystemRAM.format(mb: system.safeMaxMB))
            Text("Paper or Purpur usually handles a small server on an older Mac better than Vanilla.")
                .font(.caption).foregroundStyle(CPColor.inkFaint)
            if let lowSpecStatus {
                Text(lowSpecStatus).font(.caption).foregroundStyle(CPColor.inkDim).textSelection(.enabled)
            }
            Button("Apply low-spec settings") { applyLowSpec(memoryMB: recommended) }
                .cpButton(.secondary, size: .sm).disabled(isRunning)
        }
    }

    private func applyLowSpec(memoryMB: Int) {
        guard !isRunning else { lowSpecStatus = "Stop the server first."; return }
        do {
            _ = try ServerSettings.apply(serverDir: server.path, changes: [("view-distance", "6"), ("simulation-distance", "4")])
            server.ramMB = UInt32(memoryMB)
            lowSpecStatus = "Applied: 6 chunk view distance, 4 chunk simulation distance, and \(SystemRAM.format(mb: memoryMB)) memory. Restart OMNIServers's server to use the memory change."
            reload()
        } catch { lowSpecStatus = "Could not apply the preset: \(error.localizedDescription)" }
    }

    // MARK: - server.properties fields

    @ViewBuilder
    private func propertiesCard(_ title: String, symbol: String, fields: [SettingField]) -> some View {
        SettingsCard(title: title, symbol: symbol) {
            ForEach(fields) { field in
                FieldRow(
                    field: field,
                    current: edited[field.key] ?? field.value,
                    disabled: saving,
                    onChange: { edited[field.key] = $0; savedFlash = false }
                )
            }
        }
    }

    private func rawPropertiesCard(_ all: [(String, String)]) -> some View {
        SettingsCard(title: "All properties (raw)", symbol: "curlybraces",
                     description: "Every key in server.properties. Saved with the same button, line-preserving; online-mode is only changed if you change it here.") {
            ForEach(all, id: \.0) { kv in
                HStack {
                    Text(kv.0).font(CPFont.mono(11)).foregroundStyle(CPColor.inkDim)
                        .frame(width: 220, alignment: .leading).lineLimit(1).truncationMode(.middle)
                    TextField("", text: Binding(get: { edited[kv.0] ?? kv.1 },
                                                set: { edited[kv.0] = $0; savedFlash = false }))
                        .textFieldStyle(.roundedBorder).font(CPFont.mono(11)).disabled(saving)
                }
            }
        }
    }

    // MARK: - On disk / remove

    private var onDiskCard: some View {
        SettingsCard(title: "On disk", symbol: "folder") {
            LabeledContent("Folder", value: server.path)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            LabeledContent("Launches", value: server.launchTarget)
                .font(.system(.caption, design: .monospaced))
        }
    }

    private var removeServerCard: some View {
        SettingsCard(title: "Remove this server", symbol: "trash") {
            Text("Takes it out of OMNIServers's list. Your world and files stay exactly where they are on disk.")
                .font(.caption).foregroundStyle(CPColor.inkFaint)
            Button("Remove Server", role: .destructive) {
                showingRemoveConfirm = true
            }
            .disabled(isRunning)
            if isRunning {
                Text("Stop the server first.").font(.caption2).foregroundStyle(CPColor.warn)
            }
        }
    }

    private func removeServer() {
        modelContext.delete(server)
        onRemoved()
    }

    // MARK: - Actions

    private func reload() {
        settings = ServerSettings.read(serverDir: server.path, serverType: server.serverType)
        edited = [:]
    }

    private func apply() async {
        guard !edited.isEmpty else { return }
        saving = true
        errorText = nil
        defer { saving = false }
        do {
            _ = try ServerSettings.apply(serverDir: server.path, changes: Array(edited))
            edited = [:]
            reload()
            savedFlash = true
            Toasts.shared.show("Settings saved", detail: isRunning ? "Some changes apply after a restart" : "")
            try? await Task.sleep(for: .seconds(2))
            savedFlash = false
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// One field's row, its own top-level `View` type (not an inline
/// closure) — same reasoning as `PlayersView`'s `AddRow`.
private struct FieldRow: View {
    let field: SettingField
    let current: String
    let disabled: Bool
    let onChange: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            control
            if let help = field.help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = field.note {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(CPColor.warn)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var control: some View {
        switch field.kind {
        case .bool:
            LabeledContent(field.label) {
                CPToggle(isOn: Binding(
                    get: { current == "true" },
                    set: { onChange($0 ? "true" : "false") }
                ), disabled: disabled)
            }

        case .int:
            LabeledContent(field.label) {
                TextField("", text: Binding(
                    get: { current },
                    set: { newValue in
                        // digits (and a leading '-' for the handful of
                        // fields that accept -1, e.g. max-tick-time)
                        let filtered = newValue.filter { $0.isNumber || $0 == "-" }
                        onChange(filtered)
                    }
                ))
                .multilineTextAlignment(.trailing)
                .frame(width: 100)
                .font(.system(.body, design: .monospaced))
                .disabled(disabled)
            }

        case .enumKind:
            Picker(field.label, selection: Binding(
                get: { current },
                set: { onChange($0) }
            )) {
                ForEach(field.options, id: \.self) { option in
                    Text(option).tag(option)
                }
            }
            .disabled(disabled)

        case .text:
            LabeledContent(field.label) {
                TextField("", text: Binding(
                    get: { current },
                    set: { onChange($0) }
                ))
                .multilineTextAlignment(.trailing)
                .disabled(disabled)
            }
        }
    }
}
