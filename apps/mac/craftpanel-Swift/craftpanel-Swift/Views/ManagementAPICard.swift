import SwiftUI

/// Minecraft's native Management Server (JSON-RPC over WebSocket, MC
/// 1.21.9+ / the 26.x line) — direct port of `MgmtSection.tsx`, backed by
/// `ManagementServer`. A real gap: the Core logic already existed
/// (`ManagementServer.swift`) but had no view wired to it at all — the
/// exact kind of thing a side-by-side screenshot comparison against the
/// real app surfaces that reading the Swift source alone wouldn't.
struct ManagementAPICard: View {
    let server: ServerRecord
    var onNeedsRestart: () -> Void = {}

    @State private var status: MgmtStatus?
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        // Hidden entirely below 1.21.9 — same as the web app.
        if let status, status.supported {
            SettingsCard(title: "Management API", symbol: "bolt",
                         description: "Minecraft 1.21.9+ can be controlled live, without restarts.") {
                HStack {
                    Spacer()
                    if status.enabled {
                        Label(status.reachable ? "Live · \(status.port)" : "On · \(status.port)", systemImage: "circle.fill")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(status.reachable ? CPColor.okSoft : CPColor.inkFaint)
                    } else {
                        Text("Off").font(.caption2.weight(.medium)).foregroundStyle(CPColor.inkFaint)
                    }
                }
                Text("Minecraft 1.21.9+ ships a management API (JSON-RPC over WebSocket) — changing settings and game rules without a restart, live events, real TPS. OMNIServers can turn it on now (localhost-only, auto-generated secret); full in-app use of it is coming.")
                    .font(.caption2)
                    .foregroundStyle(CPColor.inkFaint)
                if status.enabled {
                    Button("Disable") { Task { await act { try ManagementServer.disable(serverDir: root) } } }
                        .cpButton(.ghost)
                        .disabled(busy)
                } else {
                    Button("Enable") { Task { await act { _ = try ManagementServer.enable(serverDir: root, preferredPort: 25585) } } }
                        .cpButton(.primary)
                        .disabled(busy)
                }
                if let errorText {
                    CPBanner(tone: .bad, message: errorText)
                }
            }
            .task(id: server.id) { reload() }
        } else {
            Color.clear.frame(width: 0, height: 0)
                .task(id: server.id) { reload() }
        }
    }

    private var root: URL { URL(fileURLWithPath: server.path) }

    private func reload() {
        let root = root, mc = server.mcVersion
        Task { status = await Task.detached { ManagementServer.status(serverDir: root, mcVersion: mc) }.value }
    }

    private func act(_ fn: () throws -> Void) async {
        busy = true; errorText = nil
        defer { busy = false }
        do {
            try fn()
            onNeedsRestart()
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
