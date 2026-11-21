import SwiftUI
import AppKit
import SwiftData

/// Create a server from scratch — pick a loader, a Minecraft version,
/// name it, and go. Direct UI counterpart of `CreateServerModal.tsx`,
/// backed by `Provisioner`. See that Core file's own doc comment for
/// what's deliberately not covered yet (Bedrock provisioning, modpacks).
struct CreateServerWizard: View {
    var startInModpackMode = false
    let onCreated: (ServerRecord) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Step { case loader, version, modpack, details, working }
    @Query private var existingServers: [ServerRecord]
    @Environment(ProcessManager.self) private var processes
    @State private var players = 4
    @State private var ramWarnings: [RamAdvisor.Warning] = []

    // Modpack flow (Tauri: "Browse a modpack instead").
    @State private var modpackMode = false
    /// Set when a non-Minecraft game (Terraria) was picked: no version step, its own download.
    @State private var game: ServerType?
    @State private var packQuery = ""
    @State private var packResults: [Modpacks.Hit] = []
    @State private var packLoading = false
    @State private var pickedPack: Modpacks.Hit?

    // "Your world" starting settings (applied after first boot, line-preserving).
    @State private var seed = ""
    @State private var gamemode = "survival"
    @State private var difficulty = "normal"
    @State private var motd = ""
    @State private var maxPlayers = 20
    @State private var step: Step = .loader
    /// Set when the user picks the full-width OMNIHost hero card.
    @State private var pickedOmniHost = false

    @State private var loader: Loader = .paper
    @State private var versions: [VersionInfo] = []
    @State private var loadingVersions = false
    @State private var versionsError: String?
    /// The raw id from `Provisioner.listVersions` — for Forge/NeoForge
    /// this already carries the loader build (e.g. "1.20.1-47.2.0" /
    /// "21.1.172"); `Provisioner.deriveMcVersion` recovers the MC
    /// version from it at creation time. Matches `CreateServerModal.tsx`
    /// exactly: one version list per loader, not a separate two-step
    /// MC-version-then-loader-build picker.
    @State private var versionID: String?
    @State private var showUnstable = false
    @State private var versionQuery = ""

    @State private var name = ""
    @State private var parentDir: URL?
    @State private var ramMB: Double = Double(AppDefaults.defaultRAMMB)
    @State private var javaPath: String = AppDefaults.defaultJavaPath

    @State private var progressMessage = ""
    @State private var progressPct: Int?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if step != .working { WizardSteps(current: stepIndex, labels: ["Type", "Version", "Setup"]) }
                Group {
                    switch step {
                    case .loader: loaderStep
                    case .version: versionStep
                    case .modpack: modpackStep
                    case .details: detailsStep
                    case .working: workingStep
                    }
                }
                .id(step)
                .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                        removal: .opacity))
            }
            .animation(.easeInOut(duration: 0.28), value: step)
            .background(CPColor.bg)
            .navigationTitle("Create Server")
            .ramWarningConfirmation($ramWarnings) { Task { await create() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step != .working {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .task {
            if parentDir == nil {
                parentDir = Self.defaultServersDir()
            }
            if startInModpackMode, step == .loader { modpackMode = true; step = .modpack }
        }
    }

    private var stepIndex: Int {
        switch step {
        case .loader, .modpack: 0
        case .version: 1
        case .details, .working: 2
        }
    }

    // MARK: - Step 1: loader

    private var loaderStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What kind of server?").font(CPFont.display(20, weight: .semibold)).foregroundStyle(CPColor.ink)
                    Text("Not sure? Paper is a safe pick for most friend groups.")
                        .font(.callout).foregroundStyle(CPColor.inkFaint)
                }
                // ── Full-width OMNIHost hero card ──────────────────────────────
                OmniHostHeroCard {
                    pickedOmniHost = true
                    game = .omnihost
                    modpackMode = false
                    name = "My OMNIHost Server"
                    step = .details
                }
                // ── Standard two-column type grid ─────────────────────────────
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(Loader.allCases) { l in
                        LoaderCard(loader: l, blurb: loaderBlurb(l), recommended: l == .paper) {
                            loader = l
                            modpackMode = false
                            Task { await loadVersions() }
                            step = .version
                        }
                    }
                    PackCard {
                        modpackMode = true
                        step = .modpack
                    }
                    GameCard(type: .fivem, blurb: "GTA V multiplayer. Needs a Windows or Linux PC, so it can't run on a Mac.", note: "Windows & Linux only", disabled: true) {}
                    GameCard(type: .terraria, blurb: "The sandbox adventure. Make a new server that creates its own world, or add an existing one.", note: "Windows, Mac & Linux", disabled: false) {
                        game = .terraria; modpackMode = false
                        name = "My Terraria Server"
                        step = .details
                    }
                }
            }
            .padding(20)
        }
        .background(CPColor.bg)
    }

    private func loaderBlurb(_ l: Loader) -> String {
        switch l {
        case .vanilla: "Straight from Mojang — no plugins, no mods."
        case .paper: "Vanilla-compatible, built for plugins and performance."
        case .fabric: "Lightweight modding, fast updates to new Minecraft versions."
        case .forge: "The long-established modding platform — the widest mod library."
        case .neoforge: "A modern fork of Forge, actively chasing new versions."
        }
    }

    // MARK: - Step 2b: modpack

    private var modpackStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search Modrinth modpacks", text: $packQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await searchPacks() } }
                .padding(.horizontal, 16)
            if packLoading {
                CPStateBlock(state: .loading, title: "Searching…")
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(packResults) { p in
                            Button {
                                pickedPack = p
                                if name.isEmpty || name == pickedPack?.title { name = p.title }
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    AsyncImage(url: p.iconURL.flatMap(URL.init(string:))) { img in img.resizable() } placeholder: {
                                        RoundedRectangle(cornerRadius: 6).fill(CPColor.surface3)
                                    }
                                    .frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 6))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(CPColor.ink)
                                        Text(p.description).font(.system(size: 11)).foregroundStyle(CPColor.inkFaint).lineLimit(2)
                                    }
                                    Spacer()
                                    if pickedPack?.id == p.id { Image(systemName: "checkmark").foregroundStyle(CPColor.accent) }
                                }
                                .padding(8)
                                .background(pickedPack?.id == p.id ? CPColor.surface3 : .clear, in: RoundedRectangle(cornerRadius: CPRadius.sm))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
            Button("Continue") { step = .details }
                .cpButton(.primary, block: true)
                .disabled(pickedPack == nil)
                .padding(16)
        }
        .background(CPColor.bg)
        .task { if packResults.isEmpty { await searchPacks() } }
        .toolbar {
            ToolbarItem(placement: .navigation) { Button("Back") { step = .loader } }
        }
    }

    private func searchPacks() async {
        packLoading = true
        defer { packLoading = false }
        packResults = (try? await Modpacks.search(packQuery)) ?? []
    }

    // MARK: - Step 2: version

    private var versionStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            if loadingVersions {
                CPStateBlock(state: .loading, title: "Loading \(loader.label) versions…")
            } else if let versionsError {
                CPBanner(tone: .bad, message: versionsError)
                    .padding(.horizontal, 16)
            } else {
                HStack {
                    Toggle("Show snapshots / betas", isOn: $showUnstable).toggleStyle(.checkbox)
                    Spacer()
                }
                .padding(.horizontal, 16)
                TextField("Search versions", text: $versionQuery)
                    .textFieldStyle(.roundedBorder)
                    .padding(.horizontal, 16)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filteredVersions) { v in
                            HStack {
                                Text(v.id).font(.system(.body, design: .monospaced))
                                if v.kind != "release" {
                                    Text(v.kind).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if versionID == v.id {
                                    Image(systemName: "checkmark").foregroundStyle(CPColor.accent)
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(versionID == v.id ? CPColor.surface3 : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: CPRadius.sm, style: .continuous))
                            .contentShape(Rectangle())
                            .onTapGesture { versionID = v.id }
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }

            Button("Continue") { step = .details }
                .cpButton(.primary, block: true)
                .disabled(versionID == nil)
                .padding(16)
        }
        .background(CPColor.bg)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back") { step = .loader }
            }
        }
    }

    /// Matches `visibleVersions` in `CreateServerModal.tsx`: filter to
    /// releases unless snapshots/betas are toggled on, then a plain
    /// substring search — no separate MC-version derivation here, that
    /// only matters once a version is actually picked.
    private var filteredVersions: [VersionInfo] {
        let base = showUnstable ? versions : versions.filter { $0.kind == "release" }
        let q = versionQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? base : base.filter { $0.id.lowercased().contains(q) }
    }

    private func loadVersions() async {
        loadingVersions = true; versionsError = nil; versionID = nil; versionQuery = ""
        defer { loadingVersions = false }
        do {
            versions = try await Provisioner.listVersions(loader)
        } catch {
            versionsError = error.localizedDescription
        }
    }

    // MARK: - Step 3: details

    private var detailsStep: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                SettingsCard(title: "Setup", symbol: "slider.horizontal.3") {
                    CPField(label: "Name") {
                        TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    }
                    CPField(label: "Location") {
                        HStack {
                            Text(parentDir?.path ?? "Choose a location…")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Change…") { pickFolder() }
                                .cpButton(.secondary, size: .sm)
                        }
                    }
                    if game == nil {
                        CPField(label: "Java path") {
                            TextField("Java path", text: $javaPath)
                                .font(.system(.body, design: .monospaced))
                                .textFieldStyle(.roundedBorder)
                        }
                        RamPicker(ramMB: $ramMB, kind: ramKind, players: $players, otherAllocatedMB: runningAllocatedMB)
                            .padding(.top, 4)
                    } else if pickedOmniHost {
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color(red: 0.910, green: 0.706, blue: 0.310)) // Gold #E8B44F
                            Text("Native engine (PumpkinMC), no Java needed. Downloaded once, about 100 MB.")
                                .font(.caption).foregroundStyle(CPColor.inkFaint)
                        }
                        .padding(.vertical, 4)
                        Label("Experimental: mobs, villagers and advancements aren't finished yet, and Fabric mods won't run. Best for lobbies, creative and build servers.", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(CPColor.warn)
                        RamPicker(ramMB: $ramMB, kind: ramKind, players: $players, otherAllocatedMB: runningAllocatedMB)
                            .padding(.top, 4)
                    }
                }

                if !modpackMode && (game == nil || pickedOmniHost) {
                    SettingsCard(title: "Your world", symbol: "globe.europe.africa") {
                        CPField(label: "Seed", hint: "Blank = random") {
                            TextField("", text: $seed).textFieldStyle(.roundedBorder)
                        }
                        HStack(spacing: 12) {
                            CPField(label: "Gamemode") {
                                Picker("", selection: $gamemode) {
                                    ForEach(["survival", "creative", "adventure", "spectator"], id: \.self) { Text($0.capitalized) }
                                }.labelsHidden()
                            }
                            CPField(label: "Difficulty") {
                                Picker("", selection: $difficulty) {
                                    ForEach(["peaceful", "easy", "normal", "hard"], id: \.self) { Text($0.capitalized) }
                                }.labelsHidden()
                            }
                            CPField(label: "Max players") {
                                Stepper("\(maxPlayers)", value: $maxPlayers, in: 1...200)
                            }
                        }
                        .padding(.top, 8)
                        CPField(label: "Message of the day", hint: "Shown in your friends' server list") {
                            TextField("A Minecraft Server", text: $motd).textFieldStyle(.roundedBorder)
                        }
                        .padding(.top, 8)
                    }
                }

                if let errorText {
                    CPBanner(tone: .bad, message: errorText)
                }

                Button {
                    if game != nil { Task { await create() }; return }
                    ramWarnings = RamAdvisor.warnings(chosenMB: Int(ramMB), kind: ramKind, players: players,
                                                      system: .current(), otherAllocatedMB: runningAllocatedMB)
                    if ramWarnings.isEmpty { Task { await create() } }
                } label: {
                    Text(modpackMode ? "Create from \(pickedPack?.title ?? "modpack")" : pickedOmniHost ? "Create OMNIHost Server" : "Create \(game?.label ?? loader.label) Server")
                }
                .cpButton(.primary, block: true)
                .disabled(effectiveName.isEmpty || parentDir == nil)
            }
            .padding(16)
        }
        .background(CPColor.bg)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Back") { if game != nil { game = nil; pickedOmniHost = false; step = .loader } else { step = modpackMode ? .modpack : .version } }
            }
        }
        .onAppear {
            if name.isEmpty { name = "\(loader.label) \(derivedMcVersion ?? "")".trimmingCharacters(in: .whitespaces) }
        }
    }

    private var derivedMcVersion: String? {
        versionID.map { Provisioner.deriveMcVersion(loader: loader, versionID: $0) }
    }

    private var effectiveName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var destinationDir: URL? {
        guard let parentDir else { return nil }
        let safe = effectiveName.isEmpty ? loader.label : effectiveName
        return parentDir.appending(path: safe.replacingOccurrences(of: "/", with: "-"))
    }

    private func pickFolder() {
        let panel = NSOpenPanelBridge.folderPicker()
        if let url = panel { parentDir = url }
    }

    /// `~/Documents/CraftPanel Servers` — most people never have to deal
    /// with a folder picker at all. Direct port of `default_servers_dir`.
    static func defaultServersDir() -> URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = docs.appending(path: "CraftPanel Servers")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Step 4: working

    private var workingStep: some View {
        VStack(spacing: 18) {
            VStack(spacing: 14) {
                Image(systemName: errorText == nil ? "shippingbox.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 28)).foregroundStyle(errorText == nil ? CPColor.accent : CPColor.warn)
                    .symbolEffect(.pulse, isActive: errorText == nil)
                Text(errorText == nil ? "Setting up \(effectiveName.isEmpty ? loader.label : effectiveName)" : "Setup stopped")
                    .font(CPFont.display(18, weight: .semibold)).foregroundStyle(CPColor.ink)
                ProgressView(value: progressPct.map { Double($0) / 100 })
                    .tint(CPColor.accent).frame(maxWidth: 320)
                    .animation(.easeOut(duration: 0.3), value: progressPct)
                Text(progressMessage + (progressPct.map { " · \($0)%" } ?? ""))
                    .font(.callout).foregroundStyle(CPColor.inkFaint).monospacedDigit()
                if let errorText {
                    CPBanner(tone: .bad, message: errorText).frame(maxWidth: 360)
                    Button("Back") { step = .details }.cpButton(.secondary)
                } else {
                    Text("This can take a minute the first time. You can leave this window open.")
                        .font(.caption).foregroundStyle(CPColor.inkGhost)
                }
            }
            .padding(28)
            .frame(maxWidth: 420)
            .background(CPColor.surface, in: RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous).strokeBorder(CPColor.lineSoft))
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CPColor.bg)
    }

    private var ramKind: RamAdvisor.Kind {
        if pickedOmniHost { return .bedrock }  // native binary — same low footprint as Bedrock
        return modpackMode ? .modpack : (loader == .forge || loader == .neoforge) ? .modded : .vanillaLike
    }

    private var runningAllocatedMB: Int {
        existingServers.filter { processes.isRunning($0.id) }.reduce(0) { $0 + Int($1.ramMB) }
    }

    private var takenPorts: Set<UInt16> {
        Set(existingServers.map { NetworkInfo.port(serverDir: URL(fileURLWithPath: $0.path)) })
    }

    private func createFromModpack() async {
        guard let pack = pickedPack, let dir = destinationDir else { return }
        errorText = nil
        step = .working
        progressMessage = "Getting ready…"
        do {
            let created = try await Modpacks.create(projectID: pack.projectID, dir: dir, name: effectiveName, ramMB: UInt32(ramMB),
                                                    javaPath: javaPath, takenPorts: takenPorts) { p in
                Task { @MainActor in progressMessage = p.message; progressPct = p.pct }
            }
            let record = ServerRecord(name: effectiveName, path: dir.path, serverType: created.serverType,
                                      launchTarget: created.launchTarget, mcVersion: created.mcVersion,
                                      javaPath: created.javaPath, ramMB: UInt32(ramMB))
            Attribution.stamp(serverDir: dir, origin: "created")
            onCreated(record)
            dismiss()
        } catch {
            errorText = error.localizedDescription
            step = .details
        }
    }

    private func createGame() async {
        guard let dir = destinationDir else { return }
        errorText = nil
        step = .working
        progressMessage = "Getting ready…"
        progressPct = nil
        do {
            let created = try await GameInstaller.createTerraria(dir: dir, name: effectiveName.isEmpty ? "Terraria" : effectiveName) { p in
                Task { @MainActor in progressMessage = p.message; progressPct = p.pct }
            }
            let record = ServerRecord(
                name: effectiveName.isEmpty ? "Terraria" : effectiveName, path: dir.path, serverType: created.serverType,
                launchTarget: created.launchTarget, mcVersion: nil, javaPath: "", ramMB: UInt32(ramMB)
            )
            Attribution.stamp(serverDir: dir, origin: "created")
            onCreated(record)
            dismiss()
        } catch {
            errorText = error.localizedDescription
            step = .details
        }
    }

    /// Create an OMNIHost server: download the engine if this Mac doesn't have it yet, write
    /// `pumpkin.toml` from the settings above, and register the server.
    private func createOmniHost() async {
        guard let dir = destinationDir else { return }
        errorText = nil
        step = .working
        progressMessage = "Preparing the OMNIHost engine…"
        progressPct = nil
        do {
            let engine = try await PumpkinEngine.ensureInstalled { p in
                Task { @MainActor in progressMessage = p.message; progressPct = p.pct }
            }
            progressMessage = "Creating OMNIHost server…"
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let port = Provisioner.pickFreePort(taken: takenPorts) ?? 25565
            let settings = PumpkinConfig.Settings(
                motd: motd, port: port, maxPlayers: maxPlayers,
                gamemode: gamemode, difficulty: difficulty, seed: seed)
            try PumpkinConfig.render(settings).write(to: dir.appending(path: PumpkinConfig.fileName), atomically: true, encoding: .utf8)
            BrandingManager.installOmniHostIcon(serverDir: dir)
            let record = ServerRecord(
                name: effectiveName.isEmpty ? "OMNIHost Server" : effectiveName,
                path: dir.path, serverType: .omnihost,
                launchTarget: engine.path, mcVersion: PumpkinEngine.minecraftVersion, javaPath: "", ramMB: UInt32(ramMB)
            )
            Attribution.stamp(serverDir: dir, origin: "created")
            onCreated(record)
            dismiss()
        } catch {
            errorText = error.localizedDescription
            step = .details
        }
    }

    private func create() async {
        if pickedOmniHost { await createOmniHost(); return }
        if game != nil { await createGame(); return }
        if modpackMode { await createFromModpack(); return }
        guard let versionID, let dir = destinationDir else { return }
        errorText = nil
        step = .working
        progressMessage = "Getting ready…"
        progressPct = nil

        // Forge/NeoForge send the raw picked id as the loader build;
        // every other loader has no separate build number.
        let loaderVersion = (loader == .forge || loader == .neoforge) ? versionID : nil
        let spec = CreateSpec(
            loader: loader, mcVersion: Provisioner.deriveMcVersion(loader: loader, versionID: versionID),
            loaderVersion: loaderVersion,
            dir: dir, name: effectiveName.isEmpty ? loader.label : effectiveName,
            ramMB: UInt32(ramMB), javaPath: javaPath
        )
        do {
            let created = try await Provisioner.create(spec) { p in
                Task { @MainActor in
                    progressMessage = p.message
                    progressPct = p.pct
                }
            }
            let record = ServerRecord(
                name: spec.name, path: dir.path, serverType: created.serverType,
                launchTarget: created.launchTarget, mcVersion: created.mcVersion,
                javaPath: created.javaPath, ramMB: UInt32(ramMB)
            )
            Provisioner.applyStartingSettings(dir: dir, bedrock: false, port: Provisioner.pickFreePort(taken: takenPorts),
                                              seed: seed, gamemode: gamemode, difficulty: difficulty,
                                              motd: motd, maxPlayers: UInt32(maxPlayers))
            Attribution.stamp(serverDir: dir, origin: "created")
            onCreated(record)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Full-width OMNIHost card. Same look as the other type cards (app tokens only,
/// no emoji, no custom colours). Marked "Experimental"; never "Recommended".
private struct OmniHostHeroCard: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("OMNIHost").font(CPFont.display(15, weight: .semibold)).foregroundStyle(CPColor.ink)
                    Spacer()
                    Text("Experimental").font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(CPColor.surface3, in: Capsule())
                        .foregroundStyle(CPColor.inkFaint)
                }
                Text("A fast native server engine (PumpkinMC) for Java 26.3. No Java install needed.")
                    .font(.caption).foregroundStyle(CPColor.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack {
                    Text("Lobbies and creative").font(.system(size: 10)).foregroundStyle(CPColor.inkFaint)
                    Spacer()
                    Text("Native").font(.system(size: 10)).foregroundStyle(CPColor.inkFaint)
                    Text("No Java").font(.system(size: 10)).foregroundStyle(CPColor.inkFaint)
                    Text("Low RAM").font(.system(size: 10)).foregroundStyle(CPColor.inkFaint)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? CPColor.surface2 : CPColor.surface)
        .overlay(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous)
            .strokeBorder(hovering ? CPColor.accent.opacity(0.6) : CPColor.lineSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous))
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// Loader choice as a card: what it is, how fast it runs, and whether it
/// takes plugins or mods, so nobody has to know the jargon to pick.
private struct LoaderCard: View {
    let loader: Loader
    let blurb: String
    var recommended = false
    let action: () -> Void
    @State private var hovering = false

    private var meta: (speed: Int, plugins: Bool, mods: Bool) {
        switch loader {
        case .vanilla: (3, false, false)
        case .paper: (5, true, false)
        case .fabric: (4, false, true)
        case .forge: (3, false, true)
        case .neoforge: (3, false, true)
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(loader.label).font(CPFont.display(15, weight: .semibold)).foregroundStyle(CPColor.ink)
                    Spacer()
                    if recommended {
                        Text("Recommended").font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(CPColor.accent.opacity(0.18), in: Capsule())
                            .foregroundStyle(CPColor.accent)
                    }
                }
                Text(blurb).font(.caption).foregroundStyle(CPColor.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                HStack(spacing: 3) {
                    ForEach(0..<5, id: \.self) { i in
                        Capsule().fill(i < meta.speed ? CPColor.accent : CPColor.surface3).frame(height: 4)
                    }
                }
                HStack {
                    Text("Speed").font(.system(size: 10)).foregroundStyle(CPColor.inkFaint)
                    Spacer()
                    Label("Plugins", systemImage: meta.plugins ? "checkmark" : "xmark")
                    Label("Mods", systemImage: meta.mods ? "checkmark" : "xmark")
                }
                .font(.system(size: 10)).foregroundStyle(CPColor.inkFaint).labelStyle(.titleAndIcon)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? CPColor.surface2 : CPColor.surface)
        .overlay(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous)
            .strokeBorder(hovering ? CPColor.accent.opacity(0.6) : CPColor.lineSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous))
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// Sixth tile in the type grid: start from a ready-made modpack.
private struct PackCard: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Modpack", systemImage: "shippingbox").font(CPFont.display(15, weight: .semibold)).foregroundStyle(CPColor.ink)
                Text("Pick a ready-made pack from Modrinth and we set up the rest.")
                    .font(.caption).foregroundStyle(CPColor.inkFaint).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text("Browse packs").font(.system(size: 11, weight: .medium)).foregroundStyle(CPColor.accent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovering ? CPColor.surface2 : CPColor.surface)
        .overlay(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous)
            .strokeBorder(hovering ? CPColor.accent.opacity(0.6) : CPColor.lineSoft, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .clipShape(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous))
        .scaleEffect(hovering ? 1.015 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
    }
}

/// A non-Minecraft game as a tile in the type grid.
private struct GameCard: View {
    let type: ServerType
    let blurb: String
    let note: String
    let disabled: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var shake: CGFloat = 0

    var body: some View {
        Button {
            if disabled { withAnimation(.linear(duration: 0.3)) { shake += 1 } } else { action() }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text(type.label).font(CPFont.display(15, weight: .semibold)).foregroundStyle(CPColor.ink)
                Text(blurb).font(.caption).foregroundStyle(CPColor.inkFaint).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(note).font(.system(size: 10)).foregroundStyle(CPColor.inkFaint)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
            .contentShape(Rectangle())
            .opacity(disabled ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .background(hovering && !disabled ? CPColor.surface2 : CPColor.surface)
        .overlay(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous)
            .strokeBorder(hovering && !disabled ? CPColor.accent.opacity(0.6) : CPColor.lineSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous))
        .scaleEffect(hovering && !disabled ? 1.015 : 1)
        .modifier(ShakeEffect(travel: 6, shakes: shake))
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .help(disabled ? "\(type.label)'s server software only exists for Windows and Linux" : "")
    }
}

/// A slight left-right shake, driven by an increasing counter (use inside `withAnimation`).
struct ShakeEffect: GeometryEffect {
    var travel: CGFloat = 6
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: travel * sin(shakes * .pi * 4), y: 0))
    }
}

/// Numbered progress strip across the top of the wizard.
private struct WizardSteps: View {
    let current: Int
    let labels: [String]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(i <= current ? CPColor.accent : CPColor.surface3).frame(width: 20, height: 20)
                        if i < current {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(CPColor.onAccent)
                        } else {
                            Text("\(i + 1)").font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(i == current ? CPColor.onAccent : CPColor.inkFaint)
                        }
                    }
                    Text(label).font(.system(size: 12, weight: i == current ? .semibold : .regular))
                        .foregroundStyle(i == current ? CPColor.ink : CPColor.inkFaint)
                }
                if i < labels.count - 1 {
                    Capsule().fill(i < current ? CPColor.accent : CPColor.lineSoft).frame(height: 2)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .animation(.easeInOut(duration: 0.25), value: current)
    }
}

/// A plain `NSOpenPanel` wrapper — matches the folder-pick pattern
/// already used for "Add Existing Server", just invoked synchronously
/// from this wizard's own "Change…" button instead of a `.fileImporter`.
private enum NSOpenPanelBridge {
    @MainActor static func folderPicker() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
