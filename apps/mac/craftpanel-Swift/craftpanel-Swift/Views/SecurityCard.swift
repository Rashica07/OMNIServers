import SwiftUI

/// "Security" — anti-cheat advice and suspicious-behaviour flags scraped
/// from the logs. Direct port of `SecuritySection.tsx`, backed by
/// `AntiCheat`.
struct SecurityCard: View {
    let server: ServerRecord

    @State private var advice: AntiCheatAdvice?
    @State private var suspicions: [Suspicion]?
    @State private var open: String?

    private var root: URL { URL(fileURLWithPath: server.path) }

    var body: some View {
        SettingsCard(title: "Security", symbol: "shield",
                     description: "Anti-cheat advice and suspicious-behaviour flags.") {
            if let advice, advice.supported {
                if !advice.installed.isEmpty {
                    Label("Anti-cheat: \(advice.installed.joined(separator: ", "))", systemImage: "checkmark.shield.fill")
                        .font(.caption)
                        .foregroundStyle(CPColor.ok)
                } else if advice.warn {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("This server is shared publicly and has no anti-cheat. Consider one of:")
                            .font(.caption)
                            .foregroundStyle(CPColor.warn)
                        ForEach(advice.recommended) { r in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(r.name).font(.caption.weight(.medium))
                                Text(r.blurb).font(.caption2).foregroundStyle(CPColor.inkFaint)
                            }
                        }
                    }
                    .padding(8)
                    .background(CPColor.warnSoft.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                } else {
                    Text("No anti-cheat installed — fine for a private/friends server.")
                        .font(.caption2).foregroundStyle(CPColor.inkFaint)
                }
            } else if let advice, !advice.supported {
                Text("Vanilla servers have no anti-cheat option — switch to Paper or Fabric for one.")
                    .font(.caption2).foregroundStyle(CPColor.inkFaint)
            }

            Rectangle().fill(CPColor.lineSoft).frame(height: 1)

            Text("SUSPICION SIGNALS (FROM THE LOGS)").font(.caption2).foregroundStyle(CPColor.inkFaint)
            if let suspicions {
                if suspicions.isEmpty {
                    Text("Nothing flagged.").font(.caption2).foregroundStyle(CPColor.inkFaint)
                } else {
                    ForEach(suspicions) { s in
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                open = (open == s.name) ? nil : s.name
                            } label: {
                                HStack(spacing: 6) {
                                    Text(s.name).font(.caption)
                                    Spacer()
                                    if s.flags > 0 {
                                        Text("\(s.flags) flags").font(.caption2)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(CPColor.badSoft.opacity(0.2))
                                            .foregroundStyle(CPColor.bad)
                                            .clipShape(Capsule())
                                    }
                                    if s.rejoins > 0 {
                                        Text("\(s.rejoins) rapid re-joins").font(.caption2)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(CPColor.warnSoft.opacity(0.2))
                                            .foregroundStyle(CPColor.warn)
                                            .clipShape(Capsule())
                                    }
                                }
                                .padding(6)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if open == s.name, !s.samples.isEmpty {
                                Text(s.samples.joined(separator: "\n"))
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(CPColor.inkFaint)
                                    .padding(6)
                            }
                        }
                        .background(CPColor.surface2)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            } else {
                Text("Reading logs…").font(.caption2).foregroundStyle(CPColor.inkFaint)
            }
            Text("Heuristic only — movement kicks and re-joins have innocent causes too.")
                .font(.system(size: 9)).foregroundStyle(CPColor.inkFaint)
        }
        .task(id: server.id) { reload() }
    }

    /// Log scanning (incl. gzip) runs off the main thread.
    private func reload() {
        let root = root, type = server.serverType
        Task {
            let r = await Task.detached(priority: .userInitiated) {
                (AntiCheat.advise(serverDir: root, serverType: type, isPublic: false), AntiCheat.suspicion(serverDir: root))
            }.value
            advice = r.0; suspicions = r.1
        }
    }
}
