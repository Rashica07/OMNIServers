import SwiftUI

/// "Java flags" — extra JVM flags for tuners, with an Aikar's-flags
/// preset and a "show launch command" preview. Direct port of
/// `JvmSection.tsx`, backed by `ServerRecord.jvmArgs`/`JvmArgs`.
struct JvmArgsCard: View {
    let server: ServerRecord
    @Environment(ProcessManager.self) private var processes

    @State private var draft = ""
    @State private var saved = ""
    @State private var showLaunchLine = false
    @State private var note: String?

    private var dirty: Bool { draft.trimmingCharacters(in: .whitespaces) != saved.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        SettingsCard(title: "Java flags", symbol: "terminal",
                     description: "For tuners only — the defaults are already good.") {
            Text("Extra flags added between the memory flags and -jar. Leave blank for defaults. Heap size comes from the Memory slider above.")
                .font(.caption2)
                .foregroundStyle(CPColor.inkFaint)

            TextEditor(text: $draft)
                .font(.system(.caption2, design: .monospaced))
                .frame(height: 54)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(CPColor.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(CPColor.line))

            HStack(spacing: 8) {
                Button("Save") { save(draft) }
                    .cpButton(.primary)
                    .disabled(!dirty)
                Button("Fill Aikar's Flags") { draft = JvmArgs.aikarFlags(ramMB: server.ramMB) }
                    .buttonStyle(.plain).foregroundStyle(CPColor.accent)
                if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                    Button("Clear") { draft = ""; save("") }
                        .buttonStyle(.plain).foregroundStyle(CPColor.inkFaint)
                }
                Button(showLaunchLine ? "Hide launch command" : "Show launch command") {
                    showLaunchLine.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(CPColor.accent)
            }

            if showLaunchLine {
                Text(JvmArgs.describeLaunch(record: server))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(CPColor.inkDim)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CPColor.console)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            if let note {
                Text(note).font(.caption2).foregroundStyle(CPColor.inkFaint)
            }
        }
        .task(id: server.id) {
            draft = server.jvmArgs ?? ""
            saved = draft
        }
    }

    private func save(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        server.jvmArgs = trimmed.isEmpty ? nil : trimmed
        draft = trimmed
        saved = trimmed
        note = processes.isRunning(server.id) ? "Saved — restart to apply." : "Saved."
    }
}
