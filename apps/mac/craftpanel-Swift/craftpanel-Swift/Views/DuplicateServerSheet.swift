import SwiftUI
import SwiftData

/// "Duplicate server" — copies the world, plugins/mods, and configs into
/// a new, independent server; nothing about the original changes. Direct
/// port of `CloneServerModal.tsx`, backed by `ServerDuplicator`.
struct DuplicateServerSheet: View {
    @Query private var allServers: [ServerRecord]
    let server: ServerRecord
    let onCreated: (ServerRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var busy = false
    @State private var errorText: String?

    init(server: ServerRecord, onCreated: @escaping (ServerRecord) -> Void) {
        self.server = server
        self.onCreated = onCreated
        _name = State(initialValue: "\(server.name) copy")
    }

    private var safeName: String {
        let cleaned = name.trimmingCharacters(in: .whitespaces)
            .filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "_" || $0 == "-" }
        return cleaned.isEmpty ? "server-copy" : cleaned
    }

    private var destination: URL {
        let parent = URL(fileURLWithPath: server.path).deletingLastPathComponent()
        let dirName = safeName.replacingOccurrences(of: " ", with: "-")
        return parent.appendingPathComponent(dirName)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                CPField(label: "Name", hint: "Copies \(server.name)'s world, plugins/mods, and configs into a new, independent server — nothing about the original changes.") {
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                }
                CPField(label: "Destination") {
                    Text(destination.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(CPColor.inkFaint)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if let errorText {
                    CPBanner(tone: .bad, message: errorText)
                }
                Spacer()
            }
            .padding(16)
            .background(CPColor.bg)
            .navigationTitle("Duplicate Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Copying…" : "Duplicate") { Task { await duplicate() } }
                        .cpButton(.primary)
                        .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 260)
    }

    private func duplicate() async {
        busy = true; errorText = nil
        defer { busy = false }
        let dest = destination
        let source = DuplicateSource(server)
        let finalName = name.trimmingCharacters(in: .whitespaces)
        do {
            let copied = try await Task.detached(priority: .userInitiated) {
                try ServerDuplicator.duplicate(from: source, destination: dest)
            }.value
            let record = ServerRecord(
                name: finalName, path: copied.path, serverType: copied.serverType,
                launchTarget: copied.launchTarget, mcVersion: copied.mcVersion,
                javaPath: copied.javaPath, ramMB: copied.ramMB
            )
            // Fresh port so the clone can run alongside the original (clone_server).
            let taken = Set(allServers.map { NetworkInfo.port(serverDir: URL(fileURLWithPath: $0.path)) })
            Provisioner.applyStartingSettings(dir: URL(fileURLWithPath: copied.path), bedrock: copied.serverType.isBedrock,
                                              port: Provisioner.pickFreePort(taken: taken), seed: nil, gamemode: nil,
                                              difficulty: nil, motd: nil, maxPlayers: nil)
            Attribution.stamp(serverDir: URL(fileURLWithPath: copied.path), origin: "cloned")
            onCreated(record)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
