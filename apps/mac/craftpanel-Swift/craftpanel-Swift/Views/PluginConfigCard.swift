import SwiftUI

/// Real toggles/selects/fields for the handful of EssentialsX/LuckPerms/
/// Geyser settings OMNIServers knows about, instead of hand-editing YAML
/// for them — see `PluginConfig` for exactly which keys and why only
/// these ones. Direct port of `PluginConfigSection.tsx`. Renders nothing
/// at all if none of the three plugins are installed in this server.
struct PluginConfigSection: View {
    let server: ServerRecord

    @State private var views: [PluginConfigView]?
    @State private var errorText: String?

    var body: some View {
        Group {
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(CPColor.warn)
            } else if let views {
                ForEach(views) { view in
                    PluginConfigCard(server: server, view: view, onSaved: reload)
                }
            }
        }
        .task(id: server.id) { reload() }
    }

    private func reload() {
        views = PluginConfig.detect(serverDir: URL(fileURLWithPath: server.path))
        errorText = nil
    }
}

private struct PluginConfigCard: View {
    let server: ServerRecord
    let view: PluginConfigView
    let onSaved: () -> Void

    var body: some View {
        SettingsCard(title: view.name, symbol: "slider.horizontal.3",
                     description: "Detected at \(view.file) — a few common settings, visually. Everything else is still just a file, editable in Files.") {
            ForEach(view.fields) { field in
                PluginFieldRow(server: server, pluginID: view.plugin, field: field, onSaved: onSaved)
            }
        }
    }
}

private struct PluginFieldRow: View {
    let server: ServerRecord
    let pluginID: String
    let field: FieldView
    let onSaved: () -> Void

    @State private var draft = ""
    @State private var busy = false
    @State private var errorText: String?

    private var dirty: Bool {
        field.kind != .bool && field.kind != .select && draft != (field.value ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch field.kind {
            case .bool:
                Toggle(field.label, isOn: Binding(
                    get: { draft == "true" },
                    set: { newValue in
                        let s = newValue ? "true" : "false"
                        draft = s
                        Task { await save(s) }
                    }
                ))
                .disabled(busy)

            case .select:
                Picker(field.label, selection: Binding(
                    get: { draft },
                    set: { newValue in
                        draft = newValue
                        Task { await save(newValue) }
                    }
                )) {
                    ForEach(field.options, id: \.self) { Text($0).tag($0) }
                }
                .disabled(busy)

            case .int, .text:
                LabeledContent(field.label) {
                    HStack(spacing: 6) {
                        TextField("", text: $draft)
                            .multilineTextAlignment(field.kind == .int ? .trailing : .leading)
                            .frame(width: field.kind == .int ? 90 : 180)
                            .font(field.kind == .int ? .system(.body, design: .monospaced) : .body)
                            .disabled(busy)
                            .onSubmit { if dirty { Task { await save(draft) } } }
                        if dirty {
                            Button("Save") { Task { await save(draft) } }
                                .disabled(busy)
                        }
                    }
                }
            }

            Text(field.hint).font(.caption).foregroundStyle(CPColor.inkFaint)
            Text(field.key).font(.system(size: 9, design: .monospaced)).foregroundStyle(CPColor.inkGhost)
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(CPColor.warn)
            }
        }
        .padding(.vertical, 3)
        .task(id: field.value) {
            draft = field.value ?? ""
            errorText = nil
        }
    }

    private func save(_ value: String) async {
        busy = true; errorText = nil
        defer { busy = false }
        do {
            try PluginConfig.setField(serverDir: URL(fileURLWithPath: server.path), pluginID: pluginID, key: field.key, value: value)
            onSaved()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
