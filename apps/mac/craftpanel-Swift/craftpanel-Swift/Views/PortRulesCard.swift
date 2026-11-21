import SwiftUI
import SwiftData
import AppKit

/// "Port rules": pick what the server needs open (preset or your own TCP/UDP ports), see problems before
/// friends hit them, and copy a plain request for whoever runs the router. Mirror of the Windows card.
struct PortRulesCard: View {
    let server: ServerRecord
    @Query private var allServers: [ServerRecord]
    @Environment(ProcessManager.self) private var processes

    @State private var presetID = ""
    @State private var rules: [PortRule] = []
    @State private var saved: [PortPreset] = PortRules.loadSaved(PortRules.savedFile)
    @State private var newName = ""
    @State private var copied = false

    private var presets: [PortPreset] { PortRules.builtIn + saved }

    private var otherPorts: Set<Int> {
        Set(allServers.filter { $0.id != server.id }.map { Int(NetworkInfo.port(serverDir: URL(fileURLWithPath: $0.path))) })
    }

    private var issues: [RuleIssue] {
        let running = processes.isRunning(server.id)
        return PortRules.validate(rules)
            + PortRules.findConflicts(rules, portsOfOtherServers: otherPorts) { running ? true : PortRules.portFree($0, $1) }
    }

    var body: some View {
        SettingsCard(title: "Port rules", symbol: "network.badge.shield.half.filled",
                     description: "Pick what this server needs open. OMNIServers checks for clashes and gives you a message to send to whoever runs your router.") {
            VStack(alignment: .leading, spacing: 10) {
                chips
                if let p = presets.first(where: { $0.id == presetID }), !p.note.isEmpty {
                    Text(p.note).font(.caption).foregroundStyle(CPColor.inkFaint)
                }
                ForEach(rules.indices, id: \.self) { i in row(i) }
                HStack(spacing: 8) {
                    Button { rules.append(PortRule(proto: .tcp, port: 25565)) } label: { Label("Add port", systemImage: "plus") }
                    Spacer()
                    Button(copied ? "Copied" : "Copy request") { copyRequest() }.disabled(rules.isEmpty || issues.contains { $0.level == .error })
                }
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    Label(issue.message, systemImage: issue.level == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(issue.level == .error ? CPColor.bad : CPColor.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
                saveRow
            }
        }
        .onAppear {
            guard presetID.isEmpty else { return }
            choose(defaultPreset)
            // a Java server with Geyser: Java port plus Geyser's own port, TCP and UDP
            if let g = BedrockNetwork.defaultGeyserRules(serverDir: URL(fileURLWithPath: server.path), serverType: server.serverType) {
                presetID = "minecraft-geyser"; rules = g
            }
        }
    }

    private var defaultPreset: PortPreset {
        PortRules.builtIn.first { $0.id == (server.serverType == .bedrock ? "minecraft-bedrock" : "minecraft-java") } ?? PortRules.builtIn[0]
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(presets) { p in
                Button { choose(p) } label: {
                    let on = presetID == p.id
                    Text(p.name).font(.system(size: 12, weight: on ? .semibold : .medium)).lineLimit(1).frame(maxWidth: .infinity).padding(.vertical, 6)
                        .background(on ? CPColor.accentMuted : CPColor.surface3, in: RoundedRectangle(cornerRadius: CPRadius.sm, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: CPRadius.sm, style: .continuous).strokeBorder(on ? CPColor.accent.opacity(0.7) : .clear, lineWidth: 1))
                        .foregroundStyle(on ? CPColor.accentSoft : CPColor.inkDim)
                }.buttonStyle(.plain)
            }
        }
    }

    private func row(_ i: Int) -> some View {
        HStack(spacing: 8) {
            Picker("", selection: $rules[i].proto) {
                ForEach(PortProtocol.allCases, id: \.self) { Text($0.label).tag($0) }
            }.labelsHidden().frame(width: 110)
            TextField("Port", value: $rules[i].port, format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced)).frame(width: 80)
            TextField("Label", text: $rules[i].label).textFieldStyle(.roundedBorder)
            Button(role: .destructive) { rules.remove(at: i) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }

    private var saveRow: some View {
        HStack(spacing: 8) {
            TextField("Name this set to reuse it", text: $newName).textFieldStyle(.roundedBorder)
            Button("Save preset") { saveCurrent() }
                .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || rules.isEmpty)
            if let p = saved.first(where: { $0.id == presetID }) {
                Button("Delete", role: .destructive) { saved.removeAll { $0.id == p.id }; PortRules.save(PortRules.savedFile, saved); choose(defaultPreset) }
            }
        }
    }

    private func choose(_ p: PortPreset) { presetID = p.id; rules = p.rules }

    private func saveCurrent() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        let p = PortPreset(id: "user-" + UUID().uuidString.prefix(8).lowercased(), name: name, note: "Your saved ports.", rules: rules, builtIn: false)
        saved.append(p); PortRules.save(PortRules.savedFile, saved); newName = ""; choose(p)
    }

    private func copyRequest() {
        Toasts.shared.copy(PortRules.summary(name: server.name, rules: rules), what: "Port request", detail: "Send it to whoever manages your router")
        copied = true
        Task { try? await Task.sleep(for: .milliseconds(1500)); copied = false }
    }
}
