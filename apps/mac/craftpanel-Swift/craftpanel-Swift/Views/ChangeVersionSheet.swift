import SwiftUI

/// Port of `ChangeVersionModal.tsx`: swap a stopped server's jar/loader in
/// place. Always takes a safety backup first (verified, like
/// `change_server_version`); world, mods and configs are untouched.
struct ChangeVersionSheet: View {
    @Bindable var server: ServerRecord
    @Environment(\.dismiss) private var dismiss
    @State private var loader: Loader = .paper
    @State private var versions: [VersionInfo] = []
    @State private var version: String?
    @State private var loading = false
    @State private var working = false
    @State private var progress: String?
    @State private var error: String?

    private let loaders: [Loader] = [.vanilla, .paper, .fabric]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change version / loader").font(CPFont.display(18))
            Text("Replaces only the server jar. Your world, mods, plugins and settings stay. A backup is taken first.")
                .font(.system(size: 12)).foregroundStyle(CPColor.inkDim)
            CPSegmentedPicker(selection: $loader, labels: loaders.map { ($0, $0.label) })
            CPField(label: "Minecraft version") {
                if loading {
                    ProgressView().controlSize(.small)
                } else {
                    Picker("", selection: $version) {
                        ForEach(versions.filter { $0.kind == "release" }.prefix(60)) { v in
                            Text(v.id).tag(Optional(v.id))
                        }
                    }
                    .labelsHidden()
                }
            }
            if let v = version, let mc = server.mcVersion, compare(v, mc) < 0 {
                CPBanner(tone: .warn, message: "Going back from \(mc) to \(v) can corrupt a world that was already opened in the newer version. Keep the backup.")
            }
            if let progress { Text(progress).font(.system(size: 11)).foregroundStyle(CPColor.inkFaint) }
            if let error { CPBanner(tone: .bad, message: error) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.cpButton(.ghost).disabled(working)
                Button(working ? "Working…" : "Change") { Task { await run() } }
                    .cpButton(.primary).disabled(working || version == nil)
            }
        }
        .padding(24)
        .frame(width: 460)
        .background(CPColor.surface)
        .task(id: loader) { await load() }
        .onAppear {
            if let l = Loader(rawValue: server.serverType.rawValue), loaders.contains(l) { loader = l }
        }
    }

    private func load() async {
        loading = true; error = nil
        defer { loading = false }
        do {
            versions = try await Provisioner.listVersions(loader)
            version = versions.first(where: { $0.id == server.mcVersion })?.id ?? versions.first(where: { $0.kind == "release" })?.id
        } catch { self.error = error.localizedDescription }
    }

    private func run() async {
        guard let version else { return }
        working = true; error = nil
        defer { working = false }
        let dir = URL(fileURLWithPath: server.path)
        do {
            progress = "Backing up first…"
            try await Task.detached {
                let b = try BackupManager.backupNow(dir: dir, label: "before version/loader change", trigger: "manual") { _ in }
                if try !BackupManager.verifyAndRecord(dir: dir, id: b.id) {
                    throw ProvisionError.message("The safety backup failed verification — stopping before touching anything.")
                }
            }.value
            let created = try await Provisioner.changeVersion(
                dir: dir, oldLaunchTarget: server.launchTarget, name: server.name, ramMB: server.ramMB,
                javaPath: server.javaPath, loader: loader, mcVersion: version, loaderVersion: nil
            ) { p in Task { @MainActor in progress = p.message } }
            server.serverType = created.serverType
            server.launchTarget = created.launchTarget
            server.mcVersion = created.mcVersion
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Numeric dotted-version compare ("1.20.4" < "1.21").
    private func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }
}
