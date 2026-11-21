import SwiftUI

/// Port of `JavaInstallFix.tsx` + the ErrorBanner that hosts it: when a
/// server's configured Java is missing or too old for its Minecraft version,
/// offer the fix right there — point it at a matching installed JDK, or
/// download a verified Temurin runtime — instead of a failed launch.
struct JavaFixBanner: View {
    @Bindable var server: ServerRecord
    @State private var problem: String?
    @State private var need: UInt32 = 0
    @State private var found: String?
    @State private var installing = false
    @State private var progress: String?
    @State private var error: String?

    var body: some View {
        // A real (zero-height when idle) container, so `.task` below always
        // runs — on an empty Group it never fired and the banner never showed.
        VStack(spacing: 0) {
            if let problem, !server.serverType.isBedrock {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(CPColor.warn)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(problem).font(.system(size: 12)).foregroundStyle(CPColor.ink)
                        if let progress { Text(progress).font(.system(size: 11)).foregroundStyle(CPColor.inkFaint) }
                        if let error { Text(error).font(.system(size: 11)).foregroundStyle(CPColor.bad) }
                    }
                    Spacer()
                    if let found {
                        Button("Use Java \(need)") { server.javaPath = found; Task { await evaluate() } }
                            .cpButton(.primary, size: .sm)
                    } else if let f = JavaInstaller.offerableFeature(requiredJava: need) {
                        Button(installing ? "Installing…" : "Install Java \(f)") { Task { await install(f) } }
                            .cpButton(.primary, size: .sm).disabled(installing)
                    }
                }
                .padding(12)
                .background(CPColor.warnMuted)
                .overlay(alignment: .bottom) { Rectangle().fill(CPColor.line).frame(height: 1) }
            }
        }
        .task(id: "\(server.id)|\(server.javaPath)|\(server.mcVersion ?? "")") { await evaluate() }
    }

    private func evaluate() async {
        guard let mc = server.mcVersion else { problem = nil; return }
        need = JavaProbe.requiredJava(forMC: mc)
        let info = await JavaProbe.probe(exe: server.javaPath)
        if let info, info.major >= need { problem = nil; return }
        problem = info == nil
            ? "This Mac doesn't have Java set up for this server (\(server.javaPath) not found). Minecraft \(mc) needs Java \(need)."
            : "Minecraft \(mc) needs Java \(need)+, but this server is set to Java \(info!.major)."
        found = await JavaProbe.findCompatibleJava(required: need)
    }

    private func install(_ f: UInt8) async {
        installing = true; error = nil
        defer { installing = false }
        do {
            let info = try await JavaInstaller.install(feature: f) { p in Task { @MainActor in progress = p.message } }
            server.javaPath = info.path
            progress = nil
            await evaluate()
        } catch { self.error = error.localizedDescription }
    }
}
