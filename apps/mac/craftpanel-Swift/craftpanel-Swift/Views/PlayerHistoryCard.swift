import SwiftUI

/// "Player history" — everyone who has ever joined, and how long they
/// stayed. Direct port of `PlayerHistory.tsx`'s `PlayerHistory`
/// component, backed by `PlayerAnalytics.playerHistory`. Offline-mode
/// safe: built entirely from `logs/`, keyed on name.
struct PlayerHistoryCard: View {
    let server: ServerRecord
    @Environment(ProcessManager.self) private var processes

    @State private var stats: [PlayerStat]?

    private var root: URL { URL(fileURLWithPath: server.path) }

    var body: some View {
        SettingsCard(title: "Player history", symbol: "clock.arrow.circlepath",
                     description: "Everyone who has ever joined, and how long they stayed.") {
            if let stats {
                if stats.isEmpty {
                    Text("Nobody's joined yet.").font(.caption2).foregroundStyle(CPColor.inkFaint)
                } else {
                    ForEach(stats.prefix(30)) { stat in
                        HStack {
                            HStack(spacing: 6) {
                                Text(stat.name).font(.callout)
                                if stat.online {
                                    Text("online")
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(CPColor.ok.opacity(0.15))
                                        .foregroundStyle(CPColor.okSoft)
                                        .clipShape(Capsule())
                                }
                            }
                            Spacer()
                            Text("\(Self.formatDuration(stat.totalSecs)) played · \(Self.relativeTime(stat.lastSeen))")
                                .font(.caption2)
                                .foregroundStyle(CPColor.inkFaint)
                        }
                    }
                    Text("Built from logs/ — names only (offline-mode safe).")
                        .font(.caption2).foregroundStyle(CPColor.inkGhost)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .task(id: "\(server.id)-\(processes.isRunning(server.id))") { reload() }
    }

    private func reload() {
        let root = root, online = processes.isRunning(server.id)
        Task { stats = await Task.detached(priority: .userInitiated) { PlayerAnalytics.playerHistory(serverDir: root, serverOnline: online) }.value }
    }

    private static func formatDuration(_ secs: Int64) -> String {
        let h = secs / 3600, m = (secs % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "<1m"
    }

    private static func relativeTime(_ ts: Int64) -> String {
        let delta = Int64(Date().timeIntervalSince1970) - ts
        if delta < 60 { return "just now" }
        if delta < 3600 { return "\(delta / 60)m ago" }
        if delta < 86400 { return "\(delta / 3600)h ago" }
        return "\(delta / 86400)d ago"
    }
}
