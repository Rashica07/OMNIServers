import SwiftUI

/// ⌘K — jump to a server, a tab, or an action. Direct port of
/// `CommandPalette.tsx`, presented as a real SwiftUI `.sheet` instead of
/// a hand-rolled portal + backdrop.
///
/// **Create section is honestly shorter than Tauri's**: "New server"
/// (`provision.rs`), "Join a shared world" (`join_shared`), and "Quick
/// start" templates aren't built in this app yet — only "Add an existing
/// folder" is real, so only that's listed. A command that opens nothing
/// is worse than one less command.
struct CommandPalette: View {
    let servers: [ServerRecord]
    let onGoToServer: (ServerRecord, ServerSection?) -> Void
    let onOpenOverview: () -> Void
    let onOpenSettings: () -> Void
    let onAddFolder: () -> Void
    let onDismiss: () -> Void

    @Environment(ProcessManager.self) private var processes
    @State private var query = ""
    @State private var active = 0
    @FocusState private var focused: Bool

    fileprivate struct Command: Identifiable {
        let id: String
        let label: String
        var hint: String?
        var keywords: String = ""
        let symbol: String
        let section: String
        var statusColor: Color?
        let run: () -> Void
    }

    private var allCommands: [Command] {
        var out: [Command] = []
        out.append(Command(id: "add", label: "Add an existing folder", symbol: "folder.badge.plus", section: "Create", run: onAddFolder))

        if servers.count > 1 {
            out.append(Command(id: "overview", label: "Open Overview", symbol: "square.grid.2x2", section: "Go to", run: onOpenOverview))
        }
        out.append(Command(id: "settings", label: "Open OMNIServers Settings", symbol: "gearshape", section: "Go to", run: onOpenSettings))

        for s in servers {
            let running = processes.isRunning(s.id)
            out.append(Command(
                id: "open-\(s.id)", label: "Open \(s.name)",
                hint: s.mcVersion ?? s.serverType.label, keywords: s.serverType.label,
                symbol: "server.rack", section: "Go to", statusColor: statusColor(for: s),
                run: { onGoToServer(s, nil) }
            ))
            out.append(Command(
                id: "power-\(s.id)", label: "\(s.name): \(running ? "Stop" : "Start")",
                symbol: running ? "stop.fill" : "play.fill", section: "Actions",
                run: { toggle(s) }
            ))
            for section in ServerSection.allCases where section.applies(to: s.serverType) {
                out.append(Command(
                    id: "tab-\(s.id)-\(section.rawValue)", label: "\(s.name) → \(section.label)",
                    symbol: section.symbol, section: "Go to",
                    run: { onGoToServer(s, section) }
                ))
            }
        }
        return out
    }

    private var results: [Command] {
        let all = allCommands
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            // no query: keep it short — creation + go-to-server only, not every tab
            return Array(all.filter { $0.section != "Go to" || $0.id.hasPrefix("open-") || $0.id == "overview" || $0.id == "settings" }.prefix(8))
        }
        return all
            .map { ($0, max(Self.score(trimmed, $0.label), Self.score(trimmed, $0.keywords))) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(20)
            .map(\.0)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(CPColor.inkFaint)
                TextField("Jump to a server, tab, or action…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onKeyPress(.downArrow) { active = min(active + 1, max(results.count - 1, 0)); return .handled }
                    .onKeyPress(.upArrow) { active = max(active - 1, 0); return .handled }
                    .onKeyPress(.return) {
                        if results.indices.contains(active) { run(results[active]) }
                        return .handled
                    }
                    .onKeyPress(.escape) { onDismiss(); return .handled }
                Text("esc").font(.caption2).foregroundStyle(CPColor.inkGhost)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(CPColor.surface2).clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(CPColor.surface)

            Rectangle().fill(CPColor.lineSoft).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if results.isEmpty {
                            Text("Nothing matches \"\(query)\".")
                                .font(.callout).foregroundStyle(CPColor.inkFaint)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 24)
                        } else {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, cmd in
                                CommandRow(command: cmd, isActive: i == active)
                                    .id(i)
                                    .contentShape(Rectangle())
                                    .onTapGesture { run(cmd) }
                                    .onHover { hovering in if hovering { active = i } }
                            }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: active) { _, new in
                    withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
            .frame(maxHeight: 420)
        }
        .frame(width: 520)
        .background(CPColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(CPColor.line))
        .shadow(radius: 30)
        .onChange(of: query) { active = 0 }
        .task {
            focused = true
        }
    }

    private func run(_ command: Command) {
        command.run()
        onDismiss()
    }

    private func toggle(_ server: ServerRecord) {
        let runtime = processes.runtime(for: server.id)
        if runtime.isRunning {
            try? runtime.stop()
        } else {
            try? runtime.start(record: server)
        }
    }

    private func statusColor(for server: ServerRecord) -> Color {
        switch processes.runtime(for: server.id).snapshot.status {
        case .running: CPColor.ok
        case .starting, .stopping: CPColor.warn
        case .crashed: CPColor.bad
        case .stopped, .unknown: CPColor.inkGhost
        }
    }

    /// Simple, dependency-free fuzzy score: exact > prefix > substring >
    /// in-order-subsequence. Direct port of `CommandPalette.tsx`'s `score`.
    static func score(_ query: String, _ text: String) -> Int {
        guard !query.isEmpty else { return 1 }
        let q = query.lowercased(), t = text.lowercased()
        if t == q { return 100 }
        if t.hasPrefix(q) { return 80 }
        if t.contains(q) { return 60 }
        var qi = q.startIndex
        for c in t where qi < q.endIndex {
            if c == q[qi] { qi = q.index(after: qi) }
        }
        return qi == q.endIndex ? 20 : 0
    }
}

private struct CommandRow: View {
    let command: CommandPalette.Command
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let statusColor = command.statusColor {
                Circle().fill(statusColor).frame(width: 7, height: 7)
            } else {
                Image(systemName: command.symbol).font(.caption).foregroundStyle(CPColor.inkFaint).frame(width: 14)
            }
            Text(command.label).font(.system(size: 13)).foregroundStyle(isActive ? CPColor.ink : CPColor.inkDim)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let hint = command.hint {
                Text(hint).font(.caption2).foregroundStyle(CPColor.inkFaint)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(isActive ? CPColor.surface3 : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
