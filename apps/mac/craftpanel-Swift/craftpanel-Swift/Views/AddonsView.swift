import SwiftUI

/// Modrinth-backed add-ons browser: mods/plugins, datapacks, resource
/// packs, plus the installed list with update/remove. `.searchable()`
/// instead of a hand-rolled text field + segmented control — native
/// search field behavior, scoping, and keyboard shortcuts for free.
struct AddonsView: View {
    let server: ServerRecord
    /// Pre-fills the search — used by the crash banner's "Find X" action
    /// to jump here already searching for a missing dependency.
    var initialQuery: String?

    private enum ProjectKind: String, CaseIterable, Identifiable {
        case mod = "mod", datapack = "datapack", resourcepack = "resourcepack"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .mod: "Mods / Plugins"
            case .datapack: "Datapacks"
            case .resourcepack: "Resource Packs"
            }
        }
    }

    @State private var mode: Mode = .browse
    private enum Mode: String, CaseIterable { case browse = "Browse", installed = "Installed" }

    /// CurseForge (`CurseForgeClient`) only covers mods/plugins so far —
    /// see its own doc comment. `effectiveSource` is what every action
    /// actually uses; `source` is just what the toggle remembers.
    /// `fileprivate`, not `private` — the sibling `AddonInstalledRow`
    /// struct below (a top-level type, not an extension of this one)
    /// needs to reference it too.
    fileprivate enum Source: String, CaseIterable { case modrinth = "Modrinth", curseforge = "CurseForge" }

    @State private var kind: ProjectKind = .mod
    @State private var source: Source = .modrinth
    @State private var query = ""
    @State private var hits: [AddonRow] = []
    @State private var searching = false
    @State private var installedList: [InstalledEntry] = []
    @State private var cfInstalledList: [CurseForgeInstalledEntry] = []
    @State private var busyIDs: Set<String> = []
    @State private var errorText: String?

    private var effectiveSource: Source { kind == .mod ? source : .modrinth }

    var body: some View {
        VStack(spacing: 0) {
            CPSegmentedPicker(selection: $mode, labels: [(.browse, "Browse"), (.installed, "Installed")])
                .frame(maxWidth: 260)
                .padding(10)

            Divider()

            if mode == .browse {
                browseTab
            } else {
                installedTab
            }
        }
        .navigationTitle("Add-ons")
        .task(id: server.id) { reloadInstalled() }
        .onAppear {
            if server.serverType == .vanilla, kind == .mod { kind = .datapack }
            if let initialQuery, !initialQuery.isEmpty { query = initialQuery }
        }
    }

    // MARK: - Browse

    private var browseTab: some View {
        VStack(spacing: 0) {
            HStack {
                CPSegmentedPicker(selection: $kind, labels: availableKinds.map { ($0, $0.label) })
                if kind == .mod {
                    CPSegmentedPicker(selection: $source, labels: Source.allCases.map { ($0, $0.rawValue) })
                }
            }
            .padding([.horizontal, .top], 10)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .medium)).foregroundStyle(CPColor.inkFaint)
                TextField("Search \(effectiveSource == .modrinth ? "Modrinth" : "CurseForge")", text: $query)
                    .textFieldStyle(.plain).font(.system(size: 13))
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(CPColor.inkFaint) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(CPColor.surface2, in: RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous).strokeBorder(CPColor.line))
            .padding(.horizontal, 10).padding(.top, 8)

            if kind == .resourcepack {
                ResourcePackCard(server: server)
                    .padding(10)
            }

            if let errorText {
                CPBanner(tone: .warn, message: errorText)
                    .padding(.horizontal, 10).padding(.top, 8)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if searching {
                        CPStateBlock(state: .loading, title: "Searching…")
                    } else if hits.isEmpty {
                        CPStateBlock(state: .empty, title: query.isEmpty ? "Search for \(kind.label.lowercased())." : "No results.")
                    } else {
                        ForEach(hits) { hit in
                            HitRow(
                                hit: hit, busy: busyIDs.contains(hit.id),
                                onInstall: { Task { await install(hit) } }
                            )
                        }
                    }
                }
                .padding(10)
            }
            .background(CPColor.bg)
        }
        .task(id: "\(kind.rawValue)-\(effectiveSource.rawValue)-\(server.id)") { await search() }
        .onChange(of: query) {
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                await search()
            }
        }
        .onChange(of: kind) { Task { await search() } }
        .onChange(of: source) { Task { await search() } }
    }

    private var availableKinds: [ProjectKind] {
        server.serverType == .vanilla ? [.datapack, .resourcepack] : ProjectKind.allCases
    }

    private func search() async {
        searching = true
        defer { searching = false }
        do {
            if effectiveSource == .curseforge {
                let result = try await CurseForgeClient.search(
                    serverDir: URL(fileURLWithPath: server.path), serverType: server.serverType,
                    query: query, projectType: kind.rawValue,
                    mcVersion: server.mcVersion, offset: 0, apiKey: CurseForgeClient.embeddedAPIKey
                )
                hits = result.hits.map(AddonRow.init)
            } else {
                let result = try await ModrinthClient.search(
                    serverDir: URL(fileURLWithPath: server.path), serverType: server.serverType,
                    query: query, projectType: kind.rawValue, category: nil,
                    mcVersion: server.mcVersion, offset: 0
                )
                hits = result.hits.map(AddonRow.init)
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func install(_ hit: AddonRow) async {
        busyIDs.insert(hit.id)
        defer { busyIDs.remove(hit.id) }
        do {
            if effectiveSource == .curseforge {
                guard let modID = Int64(hit.id) else { return }
                _ = try await CurseForgeClient.install(
                    serverDir: URL(fileURLWithPath: server.path), serverType: server.serverType,
                    modID: modID, mcVersion: server.mcVersion, apiKey: CurseForgeClient.embeddedAPIKey
                )
            } else if hit.projectType == "resourcepack" {
                _ = try await ModrinthClient.installResourcepack(
                    serverDir: URL(fileURLWithPath: server.path), projectID: hit.id,
                    mcVersion: server.mcVersion, prompt: "", required: false
                )
            } else {
                _ = try await ModrinthClient.install(
                    serverDir: URL(fileURLWithPath: server.path), serverType: server.serverType,
                    projectID: hit.id, projectType: hit.projectType, mcVersion: server.mcVersion
                )
            }
            reloadInstalled()
            await search()
        } catch {
            errorText = error.localizedDescription
        }
    }

    // MARK: - Installed

    /// Both sources' installs, merged — a server can have items from
    /// each at once, so filtering the list by whatever the Browse
    /// toggle currently says would hide real installs. Each row is
    /// tagged so update/remove dispatch to the right client.
    private var installedRows: [AddonInstalledRow] {
        installedList.map(AddonInstalledRow.init) + cfInstalledList.map(AddonInstalledRow.init)
    }

    private var installedTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                if let errorText {
                    CPBanner(tone: .warn, message: errorText)
                }
                if installedRows.isEmpty {
                    CPStateBlock(state: .empty, title: "Nothing installed yet.")
                } else {
                    ForEach(installedRows) { row in
                        InstalledRow(
                            row: row, busy: busyIDs.contains(row.id),
                            onUpdate: { Task { await update(row) } },
                            onRemove: { Task { await remove(row) } }
                        )
                    }
                }
            }
            .padding(10)
        }
        .background(CPColor.bg)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await checkUpdates() }
                } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
            }
        }
    }

    private func reloadInstalled() {
        installedList = ModrinthClient.installed(serverDir: URL(fileURLWithPath: server.path))
        cfInstalledList = CurseForgeClient.installed(serverDir: URL(fileURLWithPath: server.path))
    }

    private func checkUpdates() async {
        do {
            installedList = try await ModrinthClient.checkUpdates(
                serverDir: URL(fileURLWithPath: server.path), serverType: server.serverType, mcVersion: server.mcVersion
            )
            if !cfInstalledList.isEmpty {
                // a cleared/invalid CurseForge key shouldn't block the
                // Modrinth half of this check from working
                cfInstalledList = (try? await CurseForgeClient.checkUpdates(
                    serverDir: URL(fileURLWithPath: server.path), mcVersion: server.mcVersion, apiKey: CurseForgeClient.embeddedAPIKey
                )) ?? cfInstalledList
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func update(_ row: AddonInstalledRow) async {
        busyIDs.insert(row.id)
        defer { busyIDs.remove(row.id) }
        do {
            switch row.source {
            case .modrinth:
                try await ModrinthClient.updateOne(
                    serverDir: URL(fileURLWithPath: server.path), serverType: server.serverType,
                    projectID: row.id, mcVersion: server.mcVersion
                )
            case .curseforge:
                guard let modID = Int64(row.id) else { return }
                try await CurseForgeClient.updateOne(
                    serverDir: URL(fileURLWithPath: server.path), serverType: server.serverType,
                    modID: modID, mcVersion: server.mcVersion, apiKey: CurseForgeClient.embeddedAPIKey
                )
            }
            reloadInstalled()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func remove(_ row: AddonInstalledRow) async {
        busyIDs.insert(row.id)
        defer { busyIDs.remove(row.id) }
        do {
            switch row.source {
            case .modrinth:
                try ModrinthClient.removeOne(serverDir: URL(fileURLWithPath: server.path), serverType: server.serverType, projectID: row.id)
            case .curseforge:
                guard let modID = Int64(row.id) else { return }
                try CurseForgeClient.removeOne(serverDir: URL(fileURLWithPath: server.path), serverType: server.serverType, modID: modID)
            }
            reloadInstalled()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// One row shape both Modrinth and CurseForge hits render through — see
/// `CurseForgeClient`'s own doc comment for exactly what it does and
/// doesn't cover (no server/client-side split, no gallery preview).
nonisolated private struct AddonRow: Identifiable {
    var id: String
    var title: String
    var description: String
    var downloads: Int
    var iconURL: String?
    var projectType: String
    var compatible: Bool
    var installed: Bool

    init(_ h: ModrinthHit) {
        id = h.projectID; title = h.title; description = h.description; downloads = h.downloads
        iconURL = h.iconURL; projectType = h.projectType; compatible = h.compatible; installed = h.installed
    }

    init(_ h: CurseForgeHit) {
        id = h.id; title = h.title; description = h.description; downloads = h.downloads
        iconURL = h.iconURL; projectType = h.projectType; compatible = h.compatible; installed = h.installed
    }
}

/// One row shape both sources' installed lists render through.
nonisolated private struct AddonInstalledRow: Identifiable {
    var id: String
    var title: String
    var dependency: Bool
    var versionLabel: String
    var updateLabel: String?
    var source: AddonsView.Source

    init(_ e: InstalledEntry) {
        id = e.projectID; title = e.title; dependency = e.dependency
        versionLabel = "v\(e.versionNumber)"; updateLabel = e.update.map { "Update to \($0.versionNumber)" }
        source = .modrinth
    }

    /// CurseForge doesn't hand back a clean semver-style version number
    /// the way Modrinth does — shown as a source badge instead of a
    /// fabricated version string.
    init(_ e: CurseForgeInstalledEntry) {
        id = e.id; title = e.title; dependency = e.dependency
        versionLabel = "CurseForge"; updateLabel = e.update.map { _ in "Update available" }
        source = .curseforge
    }
}

private struct HitRow: View {
    let hit: AddonRow
    let busy: Bool
    let onInstall: () -> Void
    @State private var showGallery = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: hit.iconURL.flatMap(URL.init(string:))) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.15))
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .saturation(hit.compatible ? 1 : 0)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hit.title).font(.callout.weight(.medium))
                    if !hit.compatible {
                        Text("No build for your MC version").font(.caption2).foregroundStyle(CPColor.warn)
                    }
                }
                Text(hit.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Text("\(hit.downloads.formatted()) downloads").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            if hit.projectType == "resourcepack" {
                // A resource pack is a visual choice: show real screenshots.
                Button("Preview") { showGallery = true }.cpButton(.ghost, size: .sm)
                    .popover(isPresented: $showGallery) { GalleryPopover(projectID: hit.id) }
            }
            if hit.installed {
                Text("Installed").font(.caption).foregroundStyle(.secondary)
            } else if busy {
                ProgressView().controlSize(.small)
            } else {
                Button("Install", action: onInstall)
                    .cpButton(.secondary, size: .sm)
                    .disabled(!hit.compatible)
                    .help(hit.compatible ? "" : "No build published for your Minecraft version")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(CPColor.surface)
        .overlay(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous).strokeBorder(CPColor.lineSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous))
        .opacity(hit.compatible || hit.installed ? 1 : 0.55)
    }
}

/// "Resource pack" — a URL + SHA-1 pushed to every joining client.
/// OMNIServers doesn't host the pack; you host the .zip somewhere
/// reachable and paste the link, and the app downloads it once just to
/// compute the hash the client needs. Direct port of
/// `ResourcePackSection.tsx`, shown only for the Resource Packs kind —
/// same placement as the real app (inside Add-ons, not Backups; an
/// earlier version of this app put it in Backups instead, a real
/// "doesn't match the main app" gap now closed).
private struct ResourcePackCard: View {
    let server: ServerRecord

    @State private var config: ResourcePackConfig?
    @State private var urlText = ""
    @State private var promptText = ""
    @State private var required = false
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        SettingsCard(title: "Resource pack", symbol: "photo",
                     description: "A pack every player is offered (or required to accept) on join. You host the .zip — OMNIServers just downloads it once to hash it. Or pick one below.") {
            if let config, !config.url.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(config.url)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Text("sha1 \(config.sha1)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(CPColor.inkFaint)
                    Text(config.required ? "Required to join" : "Optional")
                        .font(.caption2).foregroundStyle(CPColor.inkFaint)
                }
                Button("Clear", action: { Task { await clear() } })
                    .cpButton(.danger, size: .sm)
                    .disabled(busy)
                Rectangle().fill(CPColor.lineSoft).frame(height: 1)
            }

            CPField(label: "Pack URL", hint: "A direct link to the .zip — not a page that links to one.") {
                TextField("https://example.com/mypack.zip", text: $urlText)
                    .font(.system(.caption, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
            }
            CPField(label: "Prompt (optional)", hint: "Shown to players when asked to accept it.") {
                TextField("This server uses a custom resource pack", text: $promptText)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("Require the pack to join", isOn: $required).toggleStyle(.checkbox)
            Button(busy ? "Downloading & hashing…" : "Set Resource Pack") {
                Task { await setPack() }
            }
            .cpButton(.primary)
            .disabled(busy || urlText.trimmingCharacters(in: .whitespaces).isEmpty)

            if let errorText {
                CPBanner(tone: .bad, message: errorText)
            }
        }
        .task(id: server.id) { reload() }
    }

    private func reload() {
        let c = ResourcePackManager.read(dir: URL(fileURLWithPath: server.path))
        config = c
        if !c.url.isEmpty {
            urlText = c.url
            promptText = c.prompt
            required = c.required
        }
    }

    private func setPack() async {
        busy = true; errorText = nil
        defer { busy = false }
        do {
            _ = try await ResourcePackManager.setFromURL(dir: URL(fileURLWithPath: server.path), url: urlText, prompt: promptText, required: required)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func clear() async {
        do {
            try ResourcePackManager.clear(dir: URL(fileURLWithPath: server.path))
            urlText = ""; promptText = ""; required = false
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct InstalledRow: View {
    let row: AddonInstalledRow
    let busy: Bool
    let onUpdate: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(.callout.weight(.medium))
                    if row.dependency {
                        Text("dependency").font(.caption2).foregroundStyle(.secondary)
                    }
                    if row.source == .curseforge {
                        Text("CurseForge").font(.caption2).foregroundStyle(CPColor.inkFaint)
                    }
                }
                if row.source == .modrinth {
                    Text(row.versionLabel).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            } else {
                if let updateLabel = row.updateLabel {
                    Button(updateLabel, action: onUpdate)
                        .cpButton(.primary, size: .sm)
                }
                Button("Remove", action: onRemove)
                    .cpButton(.danger, size: .sm)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(CPColor.surface)
        .overlay(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous).strokeBorder(CPColor.lineSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous))
    }
}


/// Port of the Tauri gallery strip (`modrinth_gallery`).
private struct GalleryPopover: View {
    let projectID: String
    @State private var urls: [String]?

    var body: some View {
        Group {
            if let urls {
                if urls.isEmpty {
                    Text("No screenshots published.").font(.system(size: 12)).foregroundStyle(CPColor.inkFaint).padding(20)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(urls, id: \.self) { u in
                                AsyncImage(url: URL(string: u)) { $0.resizable().aspectRatio(contentMode: .fit) } placeholder: {
                                    RoundedRectangle(cornerRadius: 8).fill(CPColor.surface3)
                                }
                                .frame(height: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                        .padding(12)
                    }
                    .frame(width: 560)
                }
            } else {
                ProgressView().padding(30)
            }
        }
        .task { urls = (try? await ModrinthClient.gallery(projectID: projectID)) ?? [] }
    }
}
