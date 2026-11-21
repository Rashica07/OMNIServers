import SwiftUI

/// Runs a real `ServerDetector.detect(at:)` pass against the chosen
/// folder and lets the user confirm/name the result before it's saved.
/// Mirrors the shape of `AddServerModal.tsx`/`CreateServerModal.tsx`'s
/// confirm step on the Tauri side — evidence and warnings surfaced
/// plainly, not hidden.
struct AddServerSheet: View {
    let folder: URL
    let onAdd: (ServerRecord) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var result: DetectionResult?
    @State private var name: String = ""
    @State private var ramMB: Double = Double(AppDefaults.defaultRAMMB)
    @State private var javaPath: String = AppDefaults.defaultJavaPath
    @State private var gameNotes: [String] = []

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    detected(result)
                } else {
                    ProgressView("Scanning \(folder.lastPathComponent)…")
                        .padding()
                }
            }
            .navigationTitle("Add Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .task {
            result = await ServerDetector.detect(at: folder)
            if name.isEmpty {
                name = folder.lastPathComponent
            }
        }
    }

    @ViewBuilder
    private func detected(_ result: DetectionResult) -> some View {
        if result.detected, let type = result.serverType, let launchTarget = result.launchTarget {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    SettingsCard(title: "Detected", symbol: "checkmark.seal.fill") {
                        LabeledContent("Type") {
                            Label(type.label, systemImage: "checkmark.seal.fill")
                                .foregroundStyle(CPColor.ok)
                        }
                        if let v = result.mcVersion {
                            LabeledContent("Minecraft version", value: v)
                        }
                        LabeledContent("Launch target", value: launchTarget)

                        if !result.evidence.isEmpty {
                            Divider().overlay(CPColor.lineSoft).padding(.vertical, 2)
                            Text("WHY WE THINK THIS")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(CPColor.inkFaint)
                            ForEach(result.evidence, id: \.self) { e in
                                Text(e).font(.system(.caption, design: .monospaced))
                            }
                        }
                        ForEach(result.warnings, id: \.self) { w in
                            CPBanner(tone: .warn, message: w)
                        }
                    }

                    SettingsCard(title: "Setup", symbol: "slider.horizontal.3") {
                        CPField(label: "Name") {
                            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                        }
                        if type.usesJava {
                            CPField(label: "Java path") {
                                TextField("Java path", text: $javaPath)
                                    .font(.system(.body, design: .monospaced))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                        if type.usesJava { LabeledContent("Memory") {
                            Slider(value: $ramMB, in: 1024...16384, step: 512) {
                                Text("Memory")
                            }
                            Text("\(Int(ramMB)) MB")
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 64, alignment: .trailing)
                        } }
                    }

                    Button {
                        let record = ServerRecord(
                            name: name.isEmpty ? folder.lastPathComponent : name,
                            path: folder.path,
                            serverType: type,
                            launchTarget: launchTarget,
                            mcVersion: result.mcVersion,
                            javaPath: type.usesJava ? javaPath : "",
                            ramMB: UInt32(ramMB)
                        )
                        if type.isGame {
                            let fix = GameServers.fix(type: type, dir: folder, name: record.name)
                            gameNotes = fix.done + fix.todo.map { "To do: " + $0 }
                        }
                        Attribution.stamp(serverDir: folder, origin: "added")
                        onAdd(record)
                        dismiss()
                    } label: {
                        Text("Add \(type.label) Server")
                    }
                    .cpButton(.primary, block: true)
                }
                .padding(16)
            }
            .background(CPColor.bg)
        } else {
            CPEmptyState(
                icon: "questionmark.folder",
                title: "Nothing detected",
                message: result.warnings.first ?? "This doesn't look like a Minecraft server folder."
            )
        }
    }
}
