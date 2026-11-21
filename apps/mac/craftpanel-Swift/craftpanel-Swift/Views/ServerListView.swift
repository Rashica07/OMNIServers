import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// The sections in column 2. Batches B–H each fill in one of the
/// `.comingSoon` cases with a real view — the case exists now so the
/// navigation shape is right from the start rather than being rebuilt
/// later.
enum ServerSection: String, CaseIterable, Identifiable, Hashable {
    case performance, console, chat, network, players, map, settings, addons, mods, worlds, backups, files, resourcepacks

    var id: String { rawValue }

    var label: String {
        switch self {
        case .performance: "Performance"
        case .console: "Console"
        case .chat: "Chat"
        case .map: "Map"
        case .network: "Network"
        case .players: "Players"
        case .settings: "Settings"
        case .addons: "Add-ons"
        case .mods: "Mods"
        case .worlds: "Worlds"
        case .backups: "Backups"
        case .files: "Files"
        case .resourcepacks: "Resource Packs"
        }
    }

    /// SF Symbols throughout — no hand-drawn SVG icon set to maintain.
    var symbol: String {
        switch self {
        case .performance: "chart.xyaxis.line"
        case .console: "terminal"
        case .chat: "bubble.left.and.bubble.right"
        case .map: "map"
        case .network: "antenna.radiowaves.left.and.right"
        case .players: "person.2"
        case .settings: "slider.horizontal.3"
        case .addons: "sparkles"
        case .mods: "shippingbox"
        case .worlds: "globe"
        case .backups: "clock.arrow.circlepath"
        case .files: "folder"
        case .resourcepacks: "photo.stack"
        }
    }

    /// Bedrock has no RCON, no Modrinth ecosystem and a different world
    /// format — same gating the Tauri app applies via `hasNoRcon`. Mods
    /// only shows for loaders that actually load from a `mods/` folder
    /// (Fabric/Forge — Paper/Spigot use plugins instead), matching the
    /// Tauri sidebar's own conditional `hasMods` tab. Resource Packs is
    /// the mirror image of Add-ons: Bedrock's own folder-based pack
    /// system (`BedrockResourcePackManager`), so it only shows there —
    /// Java servers already get resource-pack management inside Add-ons.
    func applies(to type: ServerType) -> Bool {
        if self == .mods { return ModsManager.loaderUsesMods(type) }
        if self == .resourcepacks { return type.isBedrock }
        guard type.isBedrock else { return true }
        return switch self {
        case .players, .addons, .worlds, .chat, .map: false
        default: true
        }
    }
}

/// 2-pane shell: a server-list sidebar + one content pane that owns its
/// own tab bar (`ServerDetailShell`) — the actual Tauri shape (sidebar +
/// `<main>` with an internal `<Tabs>` row), not a 3-column app.
struct ServerListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(ProcessManager.self) private var processes
    @Query(sort: \ServerRecord.createdAt) private var servers: [ServerRecord]

    @State private var selectedServer: ServerRecord?
    @Bindable private var router = AppRouter.shared
    @State private var pendingFolder: URL?
    @State private var transferTarget: ServerRecord?
    @State private var dropTargeted = false
    @AppStorage("cp.sidebarCollapsed") private var collapsed = false
    /// The fleet-summary landing page — matches the Tauri app's own
    /// "Overview" sidebar entry sitting above the server list. Starts
    /// active since there's no server selected yet; a tap on any server
    /// row clears it, a tap on "Overview" itself brings it back.
    @State private var showOverview = true
    /// App-level settings, matching the Tauri sidebar's own pinned
    /// "OMNIServers settings" footer entry — a real gap this native build
    /// had no counterpart for at all.
    @State private var showAppSettings = false
    /// ⌘K — jump to a server, a tab, or an action.
    /// Set by the palette's "Server → Tab" commands, consumed once by
    /// `ServerDetailShell` as its initial tab.
    @State private var pendingSection: ServerSection?

    var body: some View {
        VStack(spacing: 0) {
            // Checks on launch, like a game launcher — silent unless
            // there's actually something newer.
            UpdateBanner()

            // A plain two-pane layout (not NavigationSplitView) so macOS doesn't add its own sidebar button.
            HStack(spacing: 0) {
                serverColumn
                Divider().overlay(CPColor.line)
                detailColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // Re-adopt any server whose session file says it's still
            // alive from before this launch — runs once, since `.task`
            // is keyed to this view's identity and this is the root view.
            processes.adoptAll(records: servers)
            if !AppDefaults.helpTourSeen {
                router.helpContext = "tour"
                router.showHelp = true
            }
        }
        .sheet(isPresented: $router.showHelp) { HelpView(context: router.helpContext) }
        .onChange(of: router.destination) { _, dest in
            guard let dest else { return }
            router.destination = nil
            switch dest {
            case .overview:
                selectedServer = nil; showAppSettings = false; showOverview = true
            case .settings:
                selectedServer = nil; showOverview = false; showAppSettings = true
            case .server(let id, let section):
                if let s = servers.first(where: { $0.id == id }) {
                    selectedServer = s; showOverview = false; showAppSettings = false
                    pendingSection = section
                }
            }
        }
        .onChange(of: selectedServer) { _, s in router.selectedServerID = showOverview || showAppSettings ? nil : s?.id }
        .onChange(of: showOverview) { _, o in if o { router.selectedServerID = nil } }
        // Drop a server folder anywhere on the window to add it.
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        pendingFolder = url
                    } else {
                        Toasts.shared.show("Drop a folder", detail: "Drag the server's folder here, not a file", symbol: "folder")
                    }
                }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(CPColor.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(CPColor.bg.opacity(0.7))
                    .overlay { Label("Drop a server folder to add it", systemImage: "folder.badge.plus").font(.title3.weight(.medium)) }
                    .padding(8).allowsHitTesting(false)
            }
        }
        .fileImporter(isPresented: $router.showAddFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { pendingFolder = url }
        }
        .sheet(item: $pendingFolder) { folder in
            AddServerSheet(folder: folder) { newServer in
                modelContext.insert(newServer)
                selectedServer = newServer
                showOverview = false
                showAppSettings = false
            }
        }
        .sheet(item: $transferTarget) { target in
            TransferToOmniHostSheet(server: target) { newServer in
                selectedServer = newServer
                showOverview = false
                showAppSettings = false
            }
        }
        .sheet(isPresented: $router.showQuickStart) {
            QuickStartSheet { newServer in
                modelContext.insert(newServer)
                selectedServer = newServer
                showOverview = false
                showAppSettings = false
            }
        }
        .sheet(isPresented: $router.showCreate) {
            CreateServerWizard(startInModpackMode: router.createAsModpack) { newServer in
                modelContext.insert(newServer)
                selectedServer = newServer
                showOverview = false
                showAppSettings = false
            }
        }
        .background {
            // A hidden, always-present button is the standard SwiftUI way
            // to attach a window-level keyboard shortcut that isn't tied
            // to a menu-bar item — works regardless of which control has
            // focus, same as a real ⌘K palette anywhere else on macOS.
            Button("") { router.showPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()
        }
        .sheet(isPresented: $router.showPalette) {
            CommandPalette(
                servers: servers,
                onGoToServer: { server, section in
                    selectedServer = server
                    showOverview = false
                    showAppSettings = false
                    pendingSection = section
                },
                onOpenOverview: {
                    selectedServer = nil
                    showOverview = true
                    showAppSettings = false
                },
                onOpenSettings: {
                    selectedServer = nil
                    showOverview = false
                    showAppSettings = true
                },
                onAddFolder: { router.showAddFolder = true },
                onDismiss: { router.showPalette = false }
            )
            .environment(processes)
        }
    }

    private func openLauncher() {
        Task { await UpdateFlow.shared.openLauncher() }
    }

    private func openHelp() {
        router.helpContext = HelpContext.topic(settings: showAppSettings, overview: showOverview, section: router.currentSection)
        router.showHelp = true
    }

    private func openReport() {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        if let url = IssueLink.url(version: v, log: IssueLink.logTail(serverPath: selectedServer?.path)) { NSWorkspace.shared.open(url) }
    }

    /// A full-width quiet row (icon chip + label) for the expanded sidebar footer.
    private func footerRow(symbol: String, title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(CPColor.surface3)
                    Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(CPColor.inkFaint)
                }
                .frame(width: 28, height: 28)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(CPColor.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .cpTap(hoverScale: 1.0, shake: false)
        .help(help)
    }

    // MARK: Column 1 — servers

    /// The sidebar: full list, or a slim rail of large icons (toggle at the top).
    private var serverColumn: some View {
        Group { if collapsed { collapsedColumn } else { expandedColumn } }
            .frame(width: collapsed ? 76 : 250)
            .animation(.snappy(duration: 0.22), value: collapsed)
    }

    private var collapseButton: some View {
        Button { collapsed.toggle() } label: {
            Image(systemName: "sidebar.left").font(.system(size: 14, weight: .medium)).foregroundStyle(CPColor.inkFaint)
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .cpTap(hoverScale: 1.1, shake: false)
        .help(collapsed ? "Show the full sidebar" : "Shrink the sidebar to icons")
    }

    private func railTile(symbol: String? = nil, letter: String? = nil, active: Bool, dot: Color? = nil, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? CPColor.accentMuted : CPColor.surface2)
                    .overlay {
                        if let symbol { Image(systemName: symbol).font(.system(size: 20, weight: .medium)).foregroundStyle(active ? CPColor.accentSoft : CPColor.ink) }
                        else if let letter { Text(letter).font(CPFont.display(20, weight: .semibold)).foregroundStyle(active ? CPColor.accentSoft : CPColor.ink) }
                    }
                if let dot { StatusMarker(color: dot, lit: dot == CPColor.ok, size: 9).padding(4) }
            }
            .frame(width: 52, height: 52)
            .contentShape(Rectangle())
        }
        .cpTap(hoverScale: 1.06, shake: false)
        .help(help)
    }

    private var collapsedColumn: some View {
        VStack(spacing: 10) {
            collapseButton.padding(.top, 10)
            railTile(symbol: "plus", active: false, help: "New server") { router.createAsModpack = false; router.showCreate = true }
            railTile(symbol: "square.grid.2x2", active: showOverview, help: "Overview") { selectedServer = nil; showOverview = true; showAppSettings = false }
            Divider().overlay(CPColor.line).padding(.horizontal, 12)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(servers) { server in
                        railTile(letter: String(server.name.prefix(1)).uppercased(),
                                 active: !showOverview && !showAppSettings && server.id == selectedServer?.id,
                                 dot: statusColor(for: server), help: "\(server.name) · \(server.serverType.label)") { selectedServer = server }
                            .contextMenu { serverMenu(server) }
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            railTile(symbol: "cube.fill", active: false, help: "Play Minecraft: open OMNI Launcher") { openLauncher() }
            railTile(symbol: "questionmark.circle", active: false, help: "Help and tutorials") { openHelp() }
            railTile(symbol: "exclamationmark.bubble", active: false, help: "Report an issue") { openReport() }
            railTile(symbol: "gearshape.fill", active: showAppSettings, help: "OMNIServers Settings") { selectedServer = nil; showOverview = false; showAppSettings = true }
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
        .background(CPColor.surface)
        .onChange(of: selectedServer) { _, newValue in
            if newValue != nil { showOverview = false; showAppSettings = false }
        }
    }

    private var expandedColumn: some View {
        // A hand-rolled `ScrollView` + `LazyVStack`, not a native `List` —
        // `List`'s own selection highlight/insets/separators read as
        // System Settings, not OMNIServers's flat sidebar. Every row draws
        // its own hover/selected background instead.
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                SidebarNavRow(title: "Overview", symbol: "square.grid.2x2", isActive: showOverview) {
                    selectedServer = nil
                    showOverview = true
                    showAppSettings = false
                }
                .padding(.top, 6)

                SidebarNavRow(title: "Play Minecraft", symbol: "cube.fill", isActive: false) { openLauncher() }
                    .help("Open OMNI Launcher")

                Text("Your servers")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CPColor.inkFaint)
                    .padding(.top, 16)
                    .padding(.bottom, 4)
                    .padding(.horizontal, 8)

                ForEach(servers) { server in
                    SidebarServerRow(
                        server: server,
                        statusColor: statusColor(for: server),
                        isSelected: !showOverview && server.id == selectedServer?.id
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selectedServer = server }
                    .contextMenu { serverMenu(server) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .safeAreaInset(edge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Wordmark(size: 22)
                    Spacer(minLength: 0)
                    collapseButton
                    if runningCount > 0 {
                        HStack(spacing: 4) {
                            StatusMarker(color: CPColor.ok, lit: true, size: 6)
                            Text("\(runningCount)").font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(CPColor.okSoft)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(CPColor.ok.opacity(0.15))
                        .clipShape(Capsule())
                        .help("\(runningCount) server\(runningCount == 1 ? "" : "s") running")
                    }
                }
                // Tauri's split button: main half creates, the chevron opens
                // Quick start / modpacks / existing folder.
                HStack(spacing: 1) {
                    Button {
                        router.createAsModpack = false
                        router.showCreate = true
                    } label: {
                        Label("New server", systemImage: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Rectangle().fill(CPColor.onAccent.opacity(0.18)).frame(width: 1, height: 22)
                    Menu {
                        Button { router.showQuickStart = true } label: {
                            Label("Quick start — Skyblock, Bedwars, Survival…", systemImage: "sparkles")
                        }
                        Button { router.createAsModpack = true; router.showCreate = true } label: {
                            Label("Browse modpacks…", systemImage: "shippingbox")
                        }
                        Button { router.showAddFolder = true } label: {
                            Label("Add an existing folder…", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 34, height: 38)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More ways to add a server")
                }
                .foregroundStyle(CPColor.onAccent)
                .background(CPColor.accent)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(CPColor.surface)
        }
        .onChange(of: selectedServer) { _, newValue in
            if newValue != nil { showOverview = false; showAppSettings = false }
        }
        .background(CPColor.surface)
        .overlay {
            if servers.isEmpty {
                CPEmptyState(
                    icon: "server.rack",
                    title: "No servers yet",
                    message: "Add a folder with an existing Minecraft server, and OMNIServers will figure out what it is."
                )
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
            footerRow(symbol: "questionmark.circle", title: "Help & tutorials", help: "Search OMNIServers help and tutorials") { openHelp() }
            footerRow(symbol: "exclamationmark.bubble", title: "Report an issue", help: "Report a bug or send an idea. Opens a new issue on GitHub") { openReport() }
            Button {
                selectedServer = nil
                showOverview = false
                showAppSettings = true
            } label: {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(showAppSettings ? CPColor.accentMuted : CPColor.surface2)
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(showAppSettings ? CPColor.accentSoft : CPColor.inkFaint)
                    }
                    .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("OMNIServers Settings")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(CPColor.ink)
                        Text("Java, updates & more")
                            .font(.system(size: 10))
                            .foregroundStyle(CPColor.inkFaint)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CPColor.inkGhost)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            }
            .background(CPColor.surface2)
        }
    }

    @ViewBuilder
    private func serverMenu(_ server: ServerRecord) -> some View {
        let running = processes.isRunning(server.id)
        if running {
            Button("Stop") { try? processes.stop(server.id) }
        } else {
            Button("Start") {
                do { try processes.start(server) } catch { Toasts.shared.show("Couldn't start", detail: error.localizedDescription, symbol: "exclamationmark.triangle") }
            }
        }
        Button("Open") { selectedServer = server; showOverview = false; showAppSettings = false }
        if OmniHostTransfer.canTransfer(server.serverType) {
            Button("Move to OMNIHost…") { transferTarget = server }
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: server.path)]) }
        Button("Copy folder path") { Toasts.shared.copy(server.path, what: "Path") }
        Divider()
        Button("Remove from OMNIServers", role: .destructive) {
            if selectedServer?.id == server.id { selectedServer = nil; showOverview = true }
            modelContext.delete(server)
        }
        .disabled(running)
    }

    private var runningCount: Int {
        servers.count { processes.isRunning($0.id) }
    }

    private func statusColor(for server: ServerRecord) -> Color {
        switch processes.runtime(for: server.id).snapshot.status {
        case .running: CPColor.ok
        case .starting, .stopping: CPColor.warn
        case .crashed: CPColor.bad
        case .stopped, .unknown: CPColor.inkGhost
        }
    }

    // MARK: Detail — the server's own tabbed content, or Overview/Settings

    @ViewBuilder
    private var detailColumn: some View {
        if showAppSettings {
            AppSettingsView()
        } else if showOverview {
            OverviewView(servers: servers, onCreated: { newServer in
                modelContext.insert(newServer)
                selectedServer = newServer
                showOverview = false
            }) { server in
                selectedServer = server
                showOverview = false
            }
        } else if let server = selectedServer {
            // `.id` forces a fresh `ServerDetailShell` (and its
            // `@State selectedSection`) per server — without it, SwiftUI
            // can keep the previous server's selected tab when switching
            // in the sidebar, since the call site's structural identity
            // doesn't change just because `server` does.
            ServerDetailShell(server: server, pendingSection: $pendingSection, onServerRemoved: {
                selectedServer = nil
                showOverview = true
            })
                .id(server.id)
        } else {
            ContentUnavailableView(
                "Select a server",
                systemImage: "arrow.left",
                description: Text("Pick one from the list, or add a new one.")
            )
            .background(CPColor.bg)
        }
    }
}

// `.fileImporter`'s callback URL needs to conform to `Identifiable` for
// `.sheet(item:)` to key off it directly — URL doesn't by default.
extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// The "Overview" row above the server list — its own hover/active
/// background now that the sidebar isn't a native `List` anymore.
private struct SidebarNavRow: View {
    let title: String
    let symbol: String
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isActive ? CPColor.accent : CPColor.ink)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .cpTap(hoverScale: 1.0, shake: false)
        .background(isActive ? CPColor.surface3 : (hovering ? CPColor.surface2 : .clear))
        .clipShape(RoundedRectangle(cornerRadius: CPRadius.sm, style: .continuous))
        .onHover { hovering = $0 }
    }
}

/// One row in the server sidebar — its own top-level `View` type (not an
/// inline closure) so it can carry its own player-count polling without
/// re-running for every row on every sidebar redraw. Matches the "1/20"
/// badge the real Tauri sidebar shows for a running server, which this
/// native build had no counterpart for.
private struct SidebarServerRow: View {
    let server: ServerRecord
    let statusColor: Color
    let isSelected: Bool
    @Environment(ProcessManager.self) private var processes

    @State private var playerCount: (online: Int, max: Int)?
    @State private var hovering = false

    private var isRunning: Bool { processes.isRunning(server.id) }

    var body: some View {
        HStack(spacing: 8) {
            StatusMarker(color: statusColor, lit: statusColor == CPColor.ok)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(CPFont.display(13, weight: .medium))
                    .foregroundStyle(CPColor.ink)
                HStack(spacing: 4) {
                    Text(server.serverType.label)
                    if let v = server.mcVersion {
                        Text("·")
                        Text(v).font(.system(.caption, design: .monospaced))
                    }
                }
                .font(.caption)
                .foregroundStyle(CPColor.inkFaint)
            }
            Spacer()
            if isRunning, let playerCount {
                Label("\(playerCount.online)/\(playerCount.max)", systemImage: "person.2.fill")
                    .font(.caption2)
                    .foregroundStyle(CPColor.inkFaint)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? CPColor.surface3 : (hovering ? CPColor.surface2 : .clear))
        .clipShape(RoundedRectangle(cornerRadius: CPRadius.sm, style: .continuous))
        .onHover { hovering = $0 }
        .task(id: "\(server.id)-\(isRunning)") {
            guard isRunning, !server.serverType.isBedrock else { playerCount = nil; return }
            await pollPlayers()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                if Task.isCancelled { return }
                await pollPlayers()
            }
        }
    }

    private func pollPlayers() async {
        if let result = try? await RconService.shared.players(record: server) {
            playerCount = (result.online, result.max)
        }
    }
}

#Preview {
    ServerListView()
        .modelContainer(for: ServerRecord.self, inMemory: true)
        .environment(ProcessManager())
}
