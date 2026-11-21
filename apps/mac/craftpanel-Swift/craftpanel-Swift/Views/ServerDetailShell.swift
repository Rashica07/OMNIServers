import SwiftUI
import SwiftData

/// One server's whole detail pane: a persistent header (name, type/version
/// badges, status, Start/Stop) with an underline tab bar below it, and the
/// selected tab's content under that — direct port of `ServerDetail.tsx`'s
/// own `<header>` + `<Tabs>` shape.
///
/// Replaces the earlier design of a *third* NavigationSplitView column
/// listing sections — per explicit direction, that read as "3-column app",
/// not OMNIServers. This is the real Tauri shape: one sidebar (servers) +
/// one content pane that owns its own tab bar, not three stacked panes.
struct ServerDetailShell: View {
    let server: ServerRecord
    /// Set by the command palette's "Server → Tab" commands — the tab to
    /// land on. A `Binding` (not a plain value) so this can clear it
    /// immediately after applying: that's what makes "consume exactly
    /// once" correct regardless of whether this is a fresh instance (a
    /// different server was selected) or the same instance getting a new
    /// value (palette-jumping to another tab on the server already open)
    /// — a plain value read via `.onAppear` alone would leak a stale tab
    /// onto the next *different* server selected without the palette.
    @Binding var pendingSection: ServerSection?
    /// Fired when the Settings tab's "Remove Server" completes, so
    /// whoever owns `selectedServer` can clear it — this shell has no
    /// business knowing what "deselect" means at the sidebar level.
    var onServerRemoved: () -> Void = {}
    @Environment(ProcessManager.self) private var processes
    @State private var selectedSection: ServerSection = .console
    /// Set by the Console tab's crash-banner "Find X" action, consumed by
    /// `AddonsView` as its initial search — the one piece of cross-tab
    /// state this shell owns, since it's the one thing that owns tab
    /// switching in the first place.
    @State private var addonsQuery: String?
    /// Set when `start()` throws a folder-share lease conflict, so the
    /// header can offer "Start Anyway" — same recovery path as
    /// `start_inner`'s own `force` retry.
    @State private var leaseConflict: String?
    @State private var showingDuplicate = false
    @State private var showingChangeVersion = false
    @Environment(\.modelContext) private var modelContext

    private var runtime: ServerRuntime { processes.runtime(for: server.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            JavaFixBanner(server: server)
            Divider().overlay(CPColor.line)
            HStack(spacing: 0) {
                sideRail
                Divider().overlay(CPColor.line)
                // The fade lives inside a fixed-size container so a leaving page can never hold layout space beside the rail.
                ZStack {
                    content
                        .id(selectedSection)
                        .transition(.opacity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .animation(.easeOut(duration: 0.18), value: selectedSection)
                if runtime.isRunning {
                    Divider().overlay(CPColor.line)
                    playersRail
                }
            }
        }
        .background(CPColor.bg)
        .onAppear {
            if let pendingSection { selectedSection = pendingSection; self.pendingSection = nil }
            AppRouter.shared.currentSection = selectedSection.rawValue
        }
        .onChange(of: selectedSection) { _, new in AppRouter.shared.currentSection = new.rawValue }
        .onDisappear { AppRouter.shared.currentSection = nil }
        // Also handles the same-server case (the command palette can send
        // you to a different tab on the server you're already viewing,
        // where `.onAppear` alone wouldn't fire again).
        .onChange(of: runtime.snapshot.status) { _, status in manageTunnel(status) }
        .onAppear { manageTunnel(runtime.snapshot.status) }
        .onChange(of: pendingSection) { _, new in
            if let new { selectedSection = new; pendingSection = nil }
        }
        .sheet(isPresented: $showingDuplicate) {
            DuplicateServerSheet(server: server) { newRecord in
                modelContext.insert(newRecord)
            }
        }
        .sheet(isPresented: $showingChangeVersion) { ChangeVersionSheet(server: server) }
    }

    // MARK: - Actions menu

    private var actionsMenu: some View {
        Menu {
            Button {
                copyToPasteboard(LaunchInfo.inviteText(name: server.name, address: serverAddress, version: server.mcVersion), what: "Invite")
            } label: {
                Label("Copy Invite", systemImage: "paperplane")
            }

            Button {
                Task { await restartServer() }
            } label: {
                Label("Restart Server", systemImage: "arrow.clockwise")
            }
            .disabled(!runtime.isRunning)

            Button {
                showingChangeVersion = true
            } label: {
                Label("Change Version / Loader…", systemImage: "arrow.down.circle")
            }
            .disabled(runtime.isRunning || server.serverType.isBedrock)

            Button {
                showingDuplicate = true
            } label: {
                Label("Duplicate Server…", systemImage: "doc.on.doc")
            }
            .disabled(runtime.isRunning)

            Divider()

            Button(role: .destructive) {
                try? runtime.forceKill()
            } label: {
                Label("Force Kill", systemImage: "bolt.slash.fill")
            }
            .disabled(!runtime.isRunning)
        } label: {
            // The square lives inside the label so the whole thing opens the menu, not just the dots.
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(CPColor.inkDim)
                .frame(width: 36, height: 36)
                .background(CPColor.surface3, in: RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous).strokeBorder(CPColor.line))
                .contentShape(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }

    private func restartServer() async {
        guard runtime.isRunning else { return }
        try? runtime.stop()
        for _ in 0..<120 {
            try? await Task.sleep(for: .milliseconds(500))
            if !runtime.isRunning { break }
        }
        startServer(force: false)
    }

    // MARK: - Players rail

    /// Squid-style right-hand column: who is on the server right now, and a one-click invite.
    private var playersRail: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Online").font(.system(size: 12)).foregroundStyle(CPColor.inkFaint)
                Spacer()
                Text("\(runtime.online.count)").font(.system(size: 12, design: .monospaced)).foregroundStyle(CPColor.inkDim)
            }
            if runtime.online.isEmpty {
                Text("No one online yet. Send them an invite.").font(.system(size: 12)).foregroundStyle(CPColor.inkFaint)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(runtime.online, id: \.self) { name in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(CPColor.surface3).frame(width: 20, height: 20)
                                Text(name).font(.system(size: 13)).foregroundStyle(CPColor.ink).lineLimit(1)
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Button {
                copyToPasteboard(LaunchInfo.inviteText(name: server.name, address: serverAddress, version: server.mcVersion), what: "Invite")
            } label: {
                Text("Invite").font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(CPColor.lineStrong, lineWidth: 1))
            }
            .buttonStyle(.plain).foregroundStyle(CPColor.ink)
        }
        .padding(16)
        .frame(width: 200)
        .background(CPColor.surface)
    }

    // MARK: - Header

    /// Your own computer: what Join uses, whatever the shared address is.
    private var localAddress: String {
        LaunchInfo.address(lanIP: nil, port: NetworkInfo.port(serverDir: URL(fileURLWithPath: server.path)))
    }

    /// What friends use (pill, Copy, Invite): saved permanent address, else the automatic tunnel, else home network.
    private var serverAddress: String {
        let lan = LaunchInfo.address(lanIP: NetworkInfo.lanIP(), port: NetworkInfo.port(serverDir: URL(fileURLWithPath: server.path)))
        return LaunchInfo.bestAddress(manual: server.manualTunnelAddress, tunnel: PlayitAgent.shared.address(forPort: Int(NetworkInfo.port(serverDir: URL(fileURLWithPath: server.path)))) ?? TunnelManager.shared.status(server.id).address, lan: lan)
    }

    /// The address friends outside the home network use, when there is one (a saved permanent address or a tunnel).
    private var publicAddress: String? {
        let port = Int(NetworkInfo.port(serverDir: URL(fileURLWithPath: server.path)))
        let found = server.manualTunnelAddress ?? PlayitAgent.shared.address(forPort: port) ?? TunnelManager.shared.status(server.id).address
        return found?.trimmingCharacters(in: .whitespaces).isEmpty == false ? found : nil
    }

    /// Opens the free tunnel once the server is up and closes it when the server stops. Java only (the tunnel carries TCP).
    private func manageTunnel(_ status: ServerStatus) {
        guard AppDefaults.autoTunnel, !server.serverType.isBedrock, !PlayitSettings.isEnabled(server.id) else { return }
        let id = server.id
        if status == .running, !TunnelManager.shared.status(id).running {
            let port = NetworkInfo.port(serverDir: URL(fileURLWithPath: server.path))
            Task { await TunnelManager.shared.start(serverID: id, port: port) }
        } else if status == .stopped || status == .crashed {
            TunnelManager.shared.stop(serverID: id)
        }
    }

    private func copyToPasteboard(_ text: String, what: String = "Address") {
        Toasts.shared.copy(text, what: what, detail: what == "Invite" ? "Paste it to your friends" : "")
    }

    private func headerLink(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 5)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(CPColor.line, lineWidth: 1))
        }
        .buttonStyle(.plain).foregroundStyle(CPColor.ink)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(server.name)
                    .font(CPFont.display(20, weight: .medium))
                    .foregroundStyle(CPColor.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Badge(text: server.serverType.label, tone: .accent)
                    if let v = server.mcVersion {
                        Badge(text: "MC \(v)", tone: .neutral)
                    }
                    if runtime.snapshot.reattached {
                        Badge(text: "Reattached", tone: .neutral, symbol: "arrow.triangle.2.circlepath")
                    }
                }
                if runtime.isRunning {
                    HStack(spacing: 8) {
                        Button { copyToPasteboard(serverAddress) } label: {
                            HStack(spacing: 8) {
                                Text(serverAddress).font(.system(size: 12, design: .monospaced)).foregroundStyle(CPColor.ink)
                                Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundStyle(CPColor.inkFaint)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(CPColor.line, lineWidth: 1))
                        }
                        .buttonStyle(.plain).help("Copy the address")
                        headerLink("Play") {
                            Task {
                                // Java servers go through OMNI Launcher; it is downloaded first when it isn't installed.
                                if !server.serverType.isBedrock, !(server.mcVersion ?? "").isEmpty { _ = await UpdateFlow.shared.ensureLauncher() }
                                if !server.serverType.isBedrock, OMNILauncherLink.canPlay(minecraft: server.mcVersion),
                                   OMNILauncherLink.play(name: server.name, address: localAddress, publicAddress: publicAddress, minecraft: server.mcVersion ?? "") {
                                    return
                                }
                                let plan = JoinLink.plan(isBedrock: server.serverType.isBedrock, name: server.name, address: localAddress)
                                if !plan.bedrock { copyToPasteboard(plan.address); Toasts.shared.show("Open Minecraft and join", detail: "Paste the address under Multiplayer", symbol: "gamecontroller.fill") }
                                _ = JoinLink.open(plan)
                            }
                        }
                    }
                }
                let steps = LaunchInfo.steps(for: runtime.snapshot.status)
                if !steps.isEmpty {
                    HStack(spacing: 16) {
                        ForEach(steps.indices, id: \.self) { i in
                            HStack(spacing: 6) {
                                Text(steps[i].done ? "✓" : steps[i].active ? "•" : "").frame(width: 10)
                                Text(steps[i].label)
                            }
                            .font(.system(size: 11)).foregroundStyle(CPColor.inkFaint)
                            .opacity(steps[i].done || steps[i].active ? 1 : 0.5)
                        }
                    }
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                StatusPill(status: runtime.snapshot.status)
                HStack(spacing: 6) {
                    if runtime.isRunning {
                        Button {
                            try? runtime.stop()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(CPColor.ink)
                        .background(CPColor.surface3)
                        .clipShape(Capsule())
                        .disabled(runtime.snapshot.status == .stopping)
                        .opacity(runtime.snapshot.status == .stopping ? 0.5 : 1)
                    } else {
                        Button {
                            startServer(force: false)
                        } label: {
                            Label("Start", systemImage: "play.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 18).padding(.vertical, 8)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(CPColor.onAccent)
                        .background(CPColor.accent)
                        .clipShape(Capsule())
                    }
                    actionsMenu
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .alert("Server in use elsewhere", isPresented: Binding(get: { leaseConflict != nil }, set: { if !$0 { leaseConflict = nil } })) {
            Button("Cancel", role: .cancel) { leaseConflict = nil }
            Button("Start Anyway", role: .destructive) { startServer(force: true) }
        } message: {
            Text(leaseConflict ?? "")
        }
        .padding(.bottom, 12)
        .background(CPColor.surface)
    }

    // MARK: - Side rail

    private var sideRail: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(ServerSection.allCases.filter { $0.applies(to: server.serverType) }) { section in
                    TabButton(section: section, isActive: selectedSection == section) {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { selectedSection = section }
                    }
                }
            }
            .padding(8)
        }
        .frame(width: 176)
        .background(CPColor.surface)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch selectedSection {
        case .performance:
            PerformanceView(server: server, runtime: runtime)
        case .console:
            ConsoleView(record: server, runtime: runtime, onFindDependency: { modID in
                addonsQuery = modID
                selectedSection = .addons
            })
        case .chat:
            ChatView(server: server, runtime: runtime)
        case .map:
            MapView(server: server, runtime: runtime)
        case .network:
            NetworkView(server: server)
        case .players:
            PlayersView(record: server)
        case .settings:
            SettingsView(server: server, onRemoved: onServerRemoved)
        case .backups:
            BackupsView(server: server)
        case .addons:
            AddonsView(server: server, initialQuery: addonsQuery)
        case .mods:
            ModsView(server: server)
        case .worlds:
            WorldsView(server: server)
        case .files:
            FilesView(server: server)
        case .resourcepacks:
            BedrockResourcePacksView(server: server)
        }
    }

    // MARK: - Actions

    private func startServer(force: Bool) {
        do {
            try runtime.start(record: server, force: force)
            Toasts.shared.show("Starting \(server.name)", symbol: "play.circle.fill")
        } catch RconServiceError.message(let message) where message.hasPrefix("In use on") {
            leaseConflict = message
        } catch {
            runtime.push(.system, error.localizedDescription)
            Toasts.shared.error("Couldn't start \(server.name)", detail: error.localizedDescription)
        }
    }
}

/// One tab in the underline tab bar — icon + label, an accent bottom
/// border on the active tab, faint otherwise. Direct visual port of
/// `ui.tsx`'s `Tabs` component.
private struct TabButton: View {
    let section: ServerSection
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isActive ? CPColor.accentMuted : (hovering ? CPColor.surface3 : CPColor.surface2))
                    Image(systemName: section.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isActive ? CPColor.accentSoft : CPColor.inkFaint)
                }
                .frame(width: 28, height: 28)
                Text(section.label).font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isActive ? CPColor.ink : CPColor.inkDim)
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(isActive ? CPColor.surface3 : (hovering ? CPColor.surface2.opacity(0.7) : .clear),
                        in: RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous))
            .contentShape(Rectangle())
        }
        .cpTap(hoverScale: 1.0, shake: false)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isActive)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Small pill badge — direct visual port of `ui.tsx`'s `Badge`.
struct Badge: View {
    let text: String
    var tone: Tone = .neutral
    var symbol: String?

    enum Tone { case accent, neutral, ok, warn, bad, info }

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9)) }
            Text(text)
        }
        .font(.system(size: 10, weight: .medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(bg)
        .foregroundStyle(fg)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var bg: Color {
        switch tone {
        case .accent: CPColor.accentMuted.opacity(0.6)
        case .neutral: Color.clear
        case .ok: CPColor.ok.opacity(0.08)
        case .warn: CPColor.warn.opacity(0.08)
        case .bad: CPColor.bad.opacity(0.08)
        case .info: CPColor.info.opacity(0.08)
        }
    }

    private var fg: Color {
        switch tone {
        case .accent: CPColor.accentSoft
        case .neutral: CPColor.inkFaint
        case .ok: CPColor.okSoft
        case .warn: CPColor.warnSoft
        case .bad: CPColor.badSoft
        case .info: CPColor.infoSoft
        }
    }
}
