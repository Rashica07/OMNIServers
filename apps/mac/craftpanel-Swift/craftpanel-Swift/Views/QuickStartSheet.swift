import SwiftUI
import SwiftData

/// Port of `TemplateModal.tsx` ("Quick start"): a ready-made game mode —
/// Paper server, EULA accepted, the right plugin installed automatically,
/// on the newest Paper version that plugin actually supports.
struct QuickStartSheet: View {
    let onCreated: (ServerRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @Query private var existing: [ServerRecord]
    @Environment(ProcessManager.self) private var processes
    @State private var players = 4
    @State private var ramWarnings: [RamAdvisor.Warning] = []

    struct Template: Identifiable, Hashable {
        let id: String, label: String, symbol: String, blurb: String
        let plugin: (slug: String, name: String)?
        static func == (a: Template, b: Template) -> Bool { a.id == b.id }
        func hash(into h: inout Hasher) { h.combine(id) }
    }

    static let templates: [Template] = [
        .init(id: "smp", label: "Vanilla SMP", symbol: "person.3",
              blurb: "Plain survival with friends, no gimmicks — Paper for the performance headroom, nothing else installed.", plugin: nil),
        .init(id: "skyblock", label: "Skyblock", symbol: "square.stack.3d.up",
              blurb: "Start on one block that regenerates as you break it. Auto-installs OneBlock.", plugin: ("oneblock_bukkit", "OneBlock")),
        .init(id: "bedwars", label: "Bedwars", symbol: "bed.double",
              blurb: "Team PvP, protect your bed. Auto-installs BedWars1058 — you'll still set up an arena in-game.", plugin: ("bedwars1058", "BedWars1058")),
        .init(id: "essentials", label: "Survival + Essentials", symbol: "slider.horizontal.3",
              blurb: "Vanilla SMP plus /home, /tpa, /kits… Auto-installs EssentialsX.", plugin: ("essentialsx", "EssentialsX")),
    ]

    @State private var template = QuickStartSheet.templates[0]
    @State private var name = ""
    @State private var ram = Double(AppDefaults.defaultRAMMB)
    @State private var busy = false
    @State private var stage = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Quick start").font(CPFont.display(18))
                Text("A ready-made game mode — Paper server, EULA accepted, the right plugin installed automatically.")
                    .font(.system(size: 12)).foregroundStyle(CPColor.inkFaint)
            }
            VStack(spacing: 6) {
                ForEach(Self.templates) { t in
                    Button { template = t } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: t.symbol).font(.system(size: 16)).foregroundStyle(CPColor.accent).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.label).font(.system(size: 13, weight: .semibold)).foregroundStyle(CPColor.ink)
                                Text(t.blurb).font(.system(size: 11)).foregroundStyle(CPColor.inkFaint).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            if template == t { Image(systemName: "checkmark.circle.fill").foregroundStyle(CPColor.accent) }
                        }
                        .padding(10)
                        .background(template == t ? CPColor.accentMuted : CPColor.surface2, in: RoundedRectangle(cornerRadius: CPRadius.md))
                        .overlay(RoundedRectangle(cornerRadius: CPRadius.md).strokeBorder(template == t ? CPColor.accentLine : CPColor.lineSoft))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            CPField(label: "Name") { TextField(template.label, text: $name).textFieldStyle(.roundedBorder) }
            RamPicker(ramMB: $ram, kind: ramKind, players: $players, otherAllocatedMB: runningAllocatedMB)
            if busy { HStack { ProgressView().controlSize(.small); Text(stage).font(.system(size: 12)).foregroundStyle(CPColor.inkDim) } }
            if let error { CPBanner(tone: .bad, message: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.cpButton(.ghost).disabled(busy)
                Button("Create \(template.label)") {
                    ramWarnings = RamAdvisor.warnings(chosenMB: Int(ram), kind: ramKind, players: players,
                                                      system: .current(), otherAllocatedMB: runningAllocatedMB)
                    if ramWarnings.isEmpty { Task { await create() } }
                }.cpButton(.primary).disabled(busy)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(CPColor.surface)
        .ramWarningConfirmation($ramWarnings) { Task { await create() } }
    }

    private var ramKind: RamAdvisor.Kind {
        template.id == "skyblock" || template.id == "bedwars" ? .minigame : .vanillaLike
    }

    private var runningAllocatedMB: Int {
        existing.filter { processes.isRunning($0.id) }.reduce(0) { $0 + Int($1.ramMB) }
    }

    private var effectiveName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? template.label : n
    }

    private func create() async {
        guard let parent = CreateServerWizard.defaultServersDir() else { error = "No servers folder."; return }
        busy = true; error = nil
        defer { busy = false }
        let folder = effectiveName.replacingOccurrences(of: "[^A-Za-z0-9 _-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: " ", with: "-")
        var dir = parent.appending(path: folder.isEmpty ? template.id : folder)
        var n = 2
        while FileManager.default.fileExists(atPath: dir.path) { dir = parent.appending(path: "\(folder)-\(n)"); n += 1 }
        do {
            stage = "Finding a Paper version…"
            let versions = try await Provisioner.listVersions(.paper).filter { $0.kind == "release" }
            var mc = versions.first?.id
            if let p = template.plugin {
                stage = "Checking \(p.name) compatibility…"
                let supported = try await ModrinthClient.supportedVersions(project: p.slug, loader: "paper")
                guard let m = versions.first(where: { supported.contains($0.id) }) else {
                    throw ProvisionError.message("\(p.name) doesn't have a build for any available Paper version yet.")
                }
                mc = m.id
            }
            guard let mc else { throw ProvisionError.message("Couldn't find a Paper build to install.") }
            let spec = CreateSpec(loader: .paper, mcVersion: mc, loaderVersion: nil, dir: dir, name: effectiveName,
                                  ramMB: UInt32(ram), javaPath: AppDefaults.defaultJavaPath)
            let created = try await Provisioner.create(spec) { p in Task { @MainActor in stage = p.message } }
            let taken = Set(existing.map { NetworkInfo.port(serverDir: URL(fileURLWithPath: $0.path)) })
            Provisioner.applyStartingSettings(dir: dir, bedrock: false, port: Provisioner.pickFreePort(taken: taken),
                                              seed: nil, gamemode: nil, difficulty: nil, motd: nil, maxPlayers: nil)
            if let p = template.plugin {
                stage = "Installing \(p.name)…"
                _ = try await ModrinthClient.install(serverDir: dir, serverType: .paper, projectID: p.slug, projectType: "mod", mcVersion: mc)
            }
            let rec = ServerRecord(name: effectiveName, path: dir.path, serverType: created.serverType,
                                   launchTarget: created.launchTarget, mcVersion: created.mcVersion,
                                   javaPath: created.javaPath, ramMB: UInt32(ram))
            Attribution.stamp(serverDir: dir, origin: "created")
            onCreated(rec)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
