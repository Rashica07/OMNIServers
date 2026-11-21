import SwiftUI
import UniformTypeIdentifiers

/// `mods/` folder manager for Fabric/Forge servers -- every jar in the
/// folder, not just ones OMNIServers itself installed. Distinct from
/// AddonsView's "Installed" tab, which only tracks Modrinth installs.
struct ModsView: View {
    let server: ServerRecord

    @State private var list: ModList?
    @State private var errorText: String?
    @State private var busyNames: Set<String> = []
    @State private var isImporting = false

    private var root: URL { URL(fileURLWithPath: server.path) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let errorText {
                    CPBanner(tone: .bad, message: errorText)
                }
                if let list {
                    if !list.supported {
                        CPBanner(tone: .neutral, message: list.warnings.first ?? "Not supported for this server type.")
                    } else {
                        if !list.authMods.isEmpty {
                            CPBanner(
                                tone: .ok, title: "Offline-login protection is on", icon: "checkmark.shield.fill",
                                message: "\(list.authMods.joined(separator: ", ")) — players are asked for a password, so nobody can join pretending to be someone else."
                            )
                        }
                        ForEach(list.warnings, id: \.self) { w in
                            CPBanner(tone: .warn, message: w)
                        }
                        SettingsCard(title: "Add mods", symbol: "square.and.arrow.down",
                                     description: "Drop in .jar files you downloaded yourself, or browse Modrinth in the Add-ons tab.") {
                            Button("Choose .jar Files…", systemImage: "folder") { isImporting = true }
                                .cpButton(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Mods (\(enabledCount) on\(disabledCount > 0 ? " · \(disabledCount) off" : ""))")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(CPColor.inkFaint)
                            if list.mods.isEmpty {
                                CPStateBlock(state: .empty, title: "Add a .jar above, or browse Modrinth in the Add-ons tab.", compact: true)
                            } else {
                                VStack(spacing: 6) {
                                    ForEach(list.mods) { mod in
                                        ModRow(
                                            mod: mod, busy: busyNames.contains(mod.name),
                                            onToggle: { Task { await toggle(mod) } },
                                            onRemove: { Task { await remove(mod) } }
                                        )
                                    }
                                }
                            }
                            Text("Switching a mod off moves it to mods-disabled/; removing moves it to the trash.")
                                .font(.system(size: 10))
                                .foregroundStyle(CPColor.inkFaint)
                        }
                    }
                } else {
                    CPStateBlock(state: .loading)
                }
            }
            .padding(14)
        }
        .background(CPColor.bg)
        .navigationTitle("Mods")
        .task(id: server.id) { reload() }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importJars(urls) }
        }
    }

    private var enabledCount: Int { list?.mods.count { $0.enabled } ?? 0 }
    private var disabledCount: Int { (list?.mods.count ?? 0) - enabledCount }

    private func reload() {
        list = ModsManager.list(serverDir: root, serverType: server.serverType)
    }

    private func toggle(_ mod: ModFile) async {
        busyNames.insert(mod.name)
        defer { busyNames.remove(mod.name) }
        do {
            try ModsManager.setEnabled(serverDir: root, name: mod.name, enable: !mod.enabled)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func remove(_ mod: ModFile) async {
        busyNames.insert(mod.name)
        defer { busyNames.remove(mod.name) }
        do {
            try ModsManager.remove(serverDir: root, name: mod.name)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func importJars(_ urls: [URL]) {
        do {
            _ = try ModsManager.importJars(serverDir: root, sources: urls)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct ModRow: View {
    let mod: ModFile
    let busy: Bool
    let onToggle: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack {
            Toggle(isOn: Binding(get: { mod.enabled }, set: { _ in onToggle() })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mod.name)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(mod.enabled ? CPColor.ink : CPColor.inkFaint)
                    Text(mod.enabled ? ByteCountFormatter.string(fromByteCount: Int64(mod.size), countStyle: .file) : "Parked in mods-disabled/ — not loaded")
                        .font(.caption)
                        .foregroundStyle(CPColor.inkFaint)
                }
            }
            .disabled(busy)
            Spacer(minLength: 8)
            Button("Remove", action: onRemove)
                .cpButton(.danger, size: .sm)
                .disabled(busy)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CPColor.surface)
        .overlay(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous).strokeBorder(CPColor.lineSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous))
        .opacity(mod.enabled ? 1 : 0.7)
    }
}
