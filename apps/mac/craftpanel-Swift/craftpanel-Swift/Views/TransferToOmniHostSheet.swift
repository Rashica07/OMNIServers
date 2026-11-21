import SwiftUI
import SwiftData

/// "Move this server to OMNIHost": a popup that shows what moves, what doesn't, and does the copy.
/// The Java server stays exactly as it is.
struct TransferToOmniHostSheet: View {
    let server: ServerRecord
    var onCreated: (ServerRecord) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(ProcessManager.self) private var processes

    private enum Phase { case loading, ready(OmniHostTransfer.Plan), working(String), failed(String) }
    @State private var phase: Phase = .loading
    @State private var newName = ""

    private var running: Bool { processes.isRunning(server.id) }
    private var sourceDir: URL { URL(fileURLWithPath: server.path) }
    private var destDir: URL { sourceDir.deletingLastPathComponent().appending(path: newName.trimmingCharacters(in: .whitespaces), directoryHint: .isDirectory) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill").foregroundStyle(Color(red: 0.910, green: 0.706, blue: 0.310))
                Text("Move \(server.name) to OMNIHost").font(CPFont.display(18, weight: .semibold)).foregroundStyle(CPColor.ink)
            }
            switch phase {
            case .loading:
                ProgressView("Looking at your server…").frame(maxWidth: .infinity, minHeight: 120)
            case .working(let msg):
                VStack(spacing: 10) {
                    ProgressView()
                    Text(msg).font(.callout).foregroundStyle(CPColor.inkDim)
                }.frame(maxWidth: .infinity, minHeight: 140)
            case .failed(let msg):
                CPBanner(tone: .bad, message: msg)
                HStack { Spacer(); Button("Close") { dismiss() }.cpButton(.secondary) }
            case .ready(let plan):
                details(plan)
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(CPColor.bg)
        .task { await load() }
    }

    @ViewBuilder private func details(_ plan: OmniHostTransfer.Plan) -> some View {
        let s = plan.settings
        VStack(alignment: .leading, spacing: 6) {
            Label("Your world (\(OmniHostTransfer.format(plan.worldBytes))), copied, then updated to Minecraft \(PumpkinEngine.minecraftVersion)", systemImage: "checkmark.circle.fill").foregroundStyle(CPColor.ok)
            Label("Settings: port \(s.port), \(s.maxPlayers) players, \(s.gamemode), \(s.difficulty), \(s.onlineMode ? "online" : "offline") mode", systemImage: "checkmark.circle.fill").foregroundStyle(CPColor.ok)
            if plan.playerCount > 0 {
                Label("\(plan.playerCount) player\(plan.playerCount == 1 ? "" : "s"): inventory, position, stats and advancements", systemImage: "checkmark.circle.fill").foregroundStyle(CPColor.ok)
            }
            if !plan.lists.isEmpty {
                Label("Player lists: \(plan.lists.map { $0.replacingOccurrences(of: ".json", with: "") }.joined(separator: ", "))", systemImage: "checkmark.circle.fill").foregroundStyle(CPColor.ok)
            }
            Label(plan.hasIcon ? "Your server icon" : "The OMNIHost icon", systemImage: "checkmark.circle.fill").foregroundStyle(CPColor.ok)
        }
        .font(.callout)

        if plan.modCount + plan.pluginCount > 0 {
            Label(OmniHostTransfer.leftBehindSummary(plan),
                  systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(CPColor.warn).fixedSize(horizontal: false, vertical: true)
        }
        Text("Your Java server is not changed. It stays as your backup. Both use port \(s.port), so stop one before starting the other. OMNIHost is experimental: mobs and villagers aren't finished yet.")
            .font(.caption).foregroundStyle(CPColor.inkFaint).fixedSize(horizontal: false, vertical: true)

        CPField(label: "Name of the new server", hint: "Made next to the old one") {
            TextField("", text: $newName).textFieldStyle(.roundedBorder)
        }
        if running { Label("Stop the Java server first so its world isn't copied half-written.", systemImage: "exclamationmark.circle.fill").font(.caption).foregroundStyle(CPColor.warn) }
        HStack {
            Spacer()
            Button("Cancel") { dismiss() }.cpButton(.secondary)
            Button("Move to OMNIHost") { Task { await run(plan) } }
                .cpButton(.primary).disabled(running || newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func load() async {
        guard OmniHostTransfer.canTransfer(server.serverType) else { phase = .failed(OmniHostTransfer.TransferError.notJava.localizedDescription); return }
        let dir = sourceDir, name = server.name
        do {
            let plan = try await Task.detached { try OmniHostTransfer.plan(sourceDir: dir, name: name) }.value
            newName = "\(server.name) (OMNIHost)"
            phase = .ready(plan)
        } catch { phase = .failed(error.localizedDescription) }
    }

    private func run(_ plan: OmniHostTransfer.Plan) async {
        let dest = destDir
        do {
            phase = .working("Preparing the OMNIHost engine…")
            let engine = try await PumpkinEngine.ensureInstalled { p in Task { @MainActor in phase = .working(p.message) } }
            try await OmniHostTransfer.perform(plan, to: dest) { msg in Task { @MainActor in phase = .working(msg) } }
            let record = ServerRecord(name: newName.trimmingCharacters(in: .whitespaces), path: dest.path, serverType: .omnihost,
                                      launchTarget: engine.path, mcVersion: PumpkinEngine.minecraftVersion, javaPath: "", ramMB: server.ramMB)
            Attribution.stamp(serverDir: dest, origin: "transferred")
            modelContext.insert(record)
            onCreated(record)
            Toasts.shared.show("Moved to OMNIHost", detail: "\(record.name) is in your server list. Your Java server is unchanged.")
            dismiss()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
