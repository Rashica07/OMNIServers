import SwiftUI
import UniformTypeIdentifiers

/// World list — switch, create, rename, delete. Switch/rename/delete all
/// require the server to be stopped, matching the Tauri app's command
/// layer check (the underlying operations also just refuse if a name
/// collides or the active world is targeted, but the "server must be
/// stopped" rule is enforced here in the UI, same layer Rust enforced it
/// in the command handler rather than the `worlds.rs` module itself).
struct WorldsView: View {
    let server: ServerRecord
    @Environment(ProcessManager.self) private var processes

    @State private var info: WorldInfo?
    @State private var busy = false
    @State private var errorText: String?
    @State private var showingCreate = false
    @State private var renaming: World?
    @State private var renameText = ""
    @State private var isImporting = false
    @State private var useImportedNow = false
    @State private var singlePlayerWorlds: [URL] = []

    private var isRunning: Bool { processes.isRunning(server.id) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if isRunning {
                    CPBanner(tone: .info, message: "Stop the server to switch, rename, or delete worlds.")
                }
                if let errorText {
                    CPBanner(tone: .bad, message: errorText)
                }
                Button("Create New World…", systemImage: "plus") { showingCreate = true }
                    .cpButton(.secondary)
                    .disabled(isRunning || busy)

                SettingsCard(title: "Bring in a world", symbol: "square.and.arrow.down",
                             description: "Copy a world folder or .zip into this server. The original stays where it is. You can also drag a world folder or .zip onto this page.") {
                    Toggle("Use the imported world next time the server starts", isOn: $useImportedNow)
                        .font(.caption)
                    HStack(spacing: 8) {
                        Button("Choose folder or .zip…") { isImporting = true }
                            .cpButton(.primary, size: .sm).disabled(isRunning || busy)
                        Button("Find single-player saves") { singlePlayerWorlds = WorldManager.singlePlayerWorlds() }
                            .cpButton(.secondary, size: .sm).disabled(isRunning || busy)
                    }
                    ForEach(singlePlayerWorlds, id: \.path) { worldURL in
                        HStack {
                            Text(worldURL.lastPathComponent).font(.callout)
                            Spacer()
                            Button("Import") { Task { await importWorld(worldURL) } }
                                .cpButton(.secondary, size: .sm).disabled(isRunning || busy)
                        }
                    }
                }

                if (info?.worlds ?? []).isEmpty {
                    CPStateBlock(state: .empty, title: "No worlds found.", compact: true)
                } else {
                    VStack(spacing: 6) {
                        ForEach(info?.worlds ?? []) { world in
                            WorldRow(
                                world: world, disabled: isRunning || busy,
                                onSwitch: { Task { await switchTo(world.name) } },
                                onRename: { renaming = world; renameText = world.name },
                                onDelete: { Task { await delete(world.name) } },
                                onExport: { export(world.name) }
                            )
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(CPColor.bg)
        .navigationTitle("Worlds")
        .task(id: server.id) { reload() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder, .zip], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { Task { await importWorld(url) } }
            if case .failure(let error) = result { errorText = error.localizedDescription }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await importWorld(url) }
            }
            return true
        }
        .sheet(isPresented: $showingCreate) {
            CreateWorldSheet { name, seed in
                Task { await create(name: name, seed: seed) }
            }
        }
        .sheet(item: $renaming) { world in
            RenameWorldSheet(originalName: world.name, text: $renameText) {
                Task { await rename(from: world.name, to: renameText) }
            }
        }
    }

    /// Directory walk for world sizes runs off the main thread.
    private func reload() {
        let dir = URL(fileURLWithPath: server.path)
        Task { info = await Task.detached(priority: .userInitiated) { WorldManager.list(serverDir: dir) }.value }
    }

    private func switchTo(_ name: String) async {
        busy = true; errorText = nil
        defer { busy = false }
        do {
            try WorldManager.setActive(serverDir: URL(fileURLWithPath: server.path), name: name)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func create(name: String, seed: String) async {
        busy = true; errorText = nil
        defer { busy = false }
        do {
            try WorldManager.create(serverDir: URL(fileURLWithPath: server.path), name: name, seed: seed.isEmpty ? nil : seed)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func rename(from: String, to: String) async {
        busy = true; errorText = nil
        defer { busy = false }
        do {
            try WorldManager.rename(serverDir: URL(fileURLWithPath: server.path), from: from, to: to)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func delete(_ name: String) async {
        busy = true; errorText = nil
        defer { busy = false }
        do {
            try WorldManager.delete(serverDir: URL(fileURLWithPath: server.path), name: name)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func importWorld(_ source: URL) async {
        guard !isRunning else { errorText = "Stop the server before importing a world."; return }
        busy = true; errorText = nil
        defer { busy = false }
        let started = source.startAccessingSecurityScopedResource()
        defer { if started { source.stopAccessingSecurityScopedResource() } }
        let serverPath = server.path
        let activateImported = useImportedNow
        do {
            let imported = try await Task.detached(priority: .userInitiated) {
                try WorldManager.importWorld(from: source, serverDir: URL(fileURLWithPath: serverPath),
                                             activate: activateImported, serverRunning: false)
            }.value
            if let version = WorldManager.versionName(in: URL(fileURLWithPath: serverPath).appending(path: imported).appending(path: "level.dat")),
               let current = server.mcVersion, version.compare(current, options: .numeric) == .orderedDescending {
                errorText = "Imported world \(imported) was saved in Minecraft \(version), newer than this server's \(current). It may not load correctly."
            }
            reload()
        } catch { errorText = error.localizedDescription }
    }

    private func export(_ name: String) {
        let panel = NSSavePanel()
        panel.title = "Export \(name)"
        panel.nameFieldStringValue = "\(name).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        busy = true; errorText = nil
        let serverPath = server.path
        Task { @MainActor in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try WorldManager.exportWorld(serverDir: URL(fileURLWithPath: serverPath), name: name, to: destination)
                }.value
                busy = false
            } catch {
                errorText = error.localizedDescription
                busy = false
            }
        }
    }
}

private struct WorldRow: View {
    let world: World
    let disabled: Bool
    let onSwitch: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void
    let onExport: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(world.name).font(.callout.weight(.medium))
                    if world.active {
                        Text("Active").font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(CPColor.ok.opacity(0.2), in: Capsule())
                    }
                }
                HStack(spacing: 6) {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(world.sizeBytes), countStyle: .file))
                    if world.hasNether { Text("· Nether") }
                    if world.hasEnd { Text("· End") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Export", action: onExport).cpButton(.ghost, size: .sm).disabled(disabled)
            if !world.active {
                Button("Switch To", action: onSwitch).cpButton(.secondary, size: .sm).disabled(disabled)
                Button("Rename", action: onRename).cpButton(.ghost, size: .sm).disabled(disabled)
                Button("Delete", action: onDelete).cpButton(.danger, size: .sm).disabled(disabled)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(CPColor.surface)
        .overlay(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous).strokeBorder(CPColor.lineSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous))
    }
}

private struct CreateWorldSheet: View {
    let onCreate: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var seed = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                CPField(label: "World name") {
                    TextField("world-2", text: $name).textFieldStyle(.roundedBorder)
                }
                CPField(label: "Seed", hint: "Leave blank for a random one.") {
                    TextField("Seed (optional)", text: $seed).textFieldStyle(.roundedBorder)
                }
                Spacer()
            }
            .padding(16)
            .background(CPColor.bg)
            .navigationTitle("New World")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { onCreate(name, seed); dismiss() }
                        .cpButton(.primary)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 200)
    }
}

private struct RenameWorldSheet: View {
    let originalName: String
    @Binding var text: String
    let onRename: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                CPField(label: "New name") {
                    TextField("New name", text: $text).textFieldStyle(.roundedBorder)
                }
                Spacer()
            }
            .padding(16)
            .background(CPColor.bg)
            .navigationTitle("Rename \(originalName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rename") { onRename(); dismiss() }
                        .cpButton(.primary)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || text == originalName)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 160)
    }
}
