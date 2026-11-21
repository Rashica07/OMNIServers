import SwiftUI

/// The landing page — server count, running count, total memory
/// allocated, and a quick-glance list with inline Start/Stop. Direct
/// match for the Tauri app's own Overview dashboard, which this native
/// build was missing entirely: a 3-column browser with nothing to land
/// on isn't a real twin of an app whose home screen is a live fleet
/// summary.
struct OverviewView: View {
    let servers: [ServerRecord]
    var onCreated: (ServerRecord) -> Void = { _ in }
    let onSelect: (ServerRecord) -> Void
    @Environment(ProcessManager.self) private var processes
    /// Bulk actions (Tauri Dashboard's BulkAction): selection + result.
    @State private var selected: Set<UUID> = []
    @State private var bulkBusy: String?
    @State private var bulkResult: (ok: Bool, text: String)?
    @State private var lanIP: String?

    private var runningCount: Int {
        servers.count { processes.isRunning($0.id) }
    }

    private var totalMemoryMB: UInt32 {
        runningServers.reduce(0) { $0 + $1.ramMB }
    }

    private var runningServers: [ServerRecord] {
        servers.filter { processes.isRunning($0.id) }
    }

    private var crashedServers: [ServerRecord] {
        servers.filter { processes.runtime(for: $0.id).snapshot.status == .crashed }
    }

    /// `ProcessInfo.physicalMemory` — the system's real total RAM, read
    /// natively in one line. Native win over the Rust side's `sys.rs`,
    /// which has to shell out / pull in `sysinfo` for the same number.
    private var systemRAMMB: UInt64 {
        ProcessInfo.processInfo.physicalMemory / 1_048_576
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Overview")
                        .font(CPFont.display(28, weight: .medium))
                        .foregroundStyle(CPColor.ink)
                    Text("\(runningCount) of \(servers.count) server\(servers.count == 1 ? "" : "s") running")
                        .font(.callout)
                        .foregroundStyle(CPColor.inkFaint)
                }

                if !crashedServers.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(crashedServers.count == 1 ? "\(crashedServers[0].name) crashed" : "\(crashedServers.count) servers crashed")
                            .font(.callout.weight(.medium))
                    }
                    .foregroundStyle(CPColor.bad)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(CPColor.bad.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }

                fleetStrip

                if !selected.isEmpty { bulkBar }
                if let r = bulkResult {
                    CPBanner(tone: r.ok ? .ok : .bad, message: r.text)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 440), spacing: 14, alignment: .top)], spacing: 14) {
                    ForEach(servers) { server in
                        ServerCard(
                            server: server,
                            runtime: processes.runtime(for: server.id),
                            lanIP: lanIP,
                            isSelected: selected.contains(server.id),
                            onSelectToggle: {
                                if selected.contains(server.id) { selected.remove(server.id) } else { selected.insert(server.id) }
                            },
                            onOpen: { onSelect(server) },
                            onToggle: { toggle(server) }
                        )
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1180, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(CPColor.bg)
        .task { lanIP = NetworkInfo.lanIP() }
        .overlay {
            if servers.isEmpty { WelcomeCard(existing: servers, onCreated: onCreated).frame(maxWidth: .infinity, maxHeight: .infinity).background(CPColor.bg) }
        }
    }

    /// One quiet line of fleet facts instead of three equal stat boxes.
    private var fleetStrip: some View {
        HStack(spacing: 0) {
            stripItem("Servers", "\(servers.count)")
            Divider().frame(height: 28).overlay(CPColor.line)
            stripItem("Running", "\(runningCount)", color: runningCount > 0 ? CPColor.ok : CPColor.ink)
            Divider().frame(height: 28).overlay(CPColor.line)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Memory in use").font(.system(size: 12)).foregroundStyle(CPColor.inkFaint)
                    Text("\(memoryString(totalMemoryMB)) of \(memoryString(UInt32(min(UInt64(UInt32.max), systemRAMMB))))")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(CPColor.inkDim)
                }
                Capsule().fill(CPColor.surface3).frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in
                            Capsule().fill(CPColor.accent).frame(width: g.size.width * (systemRAMMB > 0 ? min(1, Double(totalMemoryMB) / Double(systemRAMMB)) : 0))
                        }
                    }
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .background(CPColor.surface, in: RoundedRectangle(cornerRadius: CPRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CPRadius.lg, style: .continuous).strokeBorder(CPColor.line))
    }

    private func stripItem(_ label: String, _ value: String, color: Color = CPColor.ink) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(CPColor.inkFaint)
            Text(value).font(CPFont.display(20, weight: .medium)).monospacedDigit().foregroundStyle(color)
        }
        .padding(.horizontal, 20).frame(width: 130, alignment: .leading)
    }

    private var bulkBar: some View {
        HStack(spacing: 10) {
            Text("\(selected.count) selected").font(.system(size: 13)).foregroundStyle(CPColor.ink)
            Spacer()
            ForEach(["Start", "Stop", "Back up"], id: \.self) { action in
                Button(bulkBusy == action ? "\(action)…" : action) { Task { await runBulk(action) } }
                    .cpButton(.secondary, size: .sm)
                    .disabled(bulkBusy != nil)
            }
            Button("Clear") { selected.removeAll() }.cpButton(.ghost, size: .sm)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(CPColor.accentMuted, in: RoundedRectangle(cornerRadius: CPRadius.lg))
        .overlay(RoundedRectangle(cornerRadius: CPRadius.lg).strokeBorder(CPColor.accentLine))
    }

    /// One honest summary for N servers, like the Tauri Dashboard.
    private func runBulk(_ action: String) async {
        bulkBusy = action
        defer { bulkBusy = nil }
        var ok = 0, failed = 0
        for server in servers where selected.contains(server.id) {
            do {
                switch action {
                case "Start": try processes.start(server)
                case "Stop": try processes.stop(server.id)
                default:
                    let dir = URL(fileURLWithPath: server.path)
                    try await processes.withSavesPaused(server.id) {
                        try await Task.detached(priority: .userInitiated) {
                            _ = try BackupManager.backupNow(dir: dir, label: "bulk", trigger: "manual") { _ in }
                            BackupManager.applyRetention(dir: dir)
                        }.value
                    }
                }
                ok += 1
            } catch { failed += 1 }
        }
        let verb = action == "Back up" ? "backed up" : (action == "Start" ? "started" : "stopped")
        if failed == 0 {
            bulkResult = (true, "\(ok) server\(ok == 1 ? "" : "s") \(verb)")
            if action != "Back up" { selected.removeAll() }
        } else {
            bulkResult = (false, "\(ok) \(verb), \(failed) failed — open each server to see why.")
        }
    }

    private func memoryString(_ mb: UInt32) -> String {
        mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024) : "\(mb) MB"
    }

    private func toggle(_ server: ServerRecord) {
        let runtime = processes.runtime(for: server.id)
        if runtime.isRunning {
            try? runtime.stop()
        } else {
            try? runtime.start(record: server)
        }
    }
}

/// One server as a card: state at a glance, live numbers and the address while it runs, one primary action.
private struct ServerCard: View {
    let server: ServerRecord
    let runtime: ServerRuntime
    let lanIP: String?
    let isSelected: Bool
    let onSelectToggle: () -> Void
    let onOpen: () -> Void
    let onToggle: () -> Void

    @State private var sample: (ramMB: Double, cpu: Double)?
    @State private var hovering = false

    private var running: Bool { runtime.isRunning }
    private var status: ServerStatus { runtime.snapshot.status }
    private var statusColor: Color {
        switch status { case .running: CPColor.ok; case .starting, .stopping: CPColor.warn; case .crashed: CPColor.bad; default: CPColor.inkGhost }
    }
    private var address: String { LaunchInfo.address(lanIP: lanIP, port: NetworkInfo.port(serverDir: URL(fileURLWithPath: server.path))) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onSelectToggle() }))
                    .toggleStyle(.checkbox).labelsHidden().opacity(isSelected || hovering ? 1 : 0.35)
                    .accessibilityLabel("Select \(server.name)")
                StatusMarker(color: statusColor, lit: status == .running)
                Text(server.name).font(CPFont.display(16, weight: .medium)).foregroundStyle(CPColor.ink).lineLimit(1)
                Spacer(minLength: 8)
                Text(status.rawValue).font(.system(size: 11)).foregroundStyle(statusColor)
            }
            HStack(spacing: 6) {
                Text(server.serverType.label)
                if let v = server.mcVersion { Text("·"); Text(v).font(.system(size: 12, design: .monospaced)) }
                Text("·"); Text(server.ramMB >= 1024 ? String(format: "%.1f GB", Double(server.ramMB) / 1024) : "\(server.ramMB) MB")
            }
            .font(.system(size: 12)).foregroundStyle(CPColor.inkFaint)

            if running {
                Text(address).font(.system(size: 12, design: .monospaced)).foregroundStyle(CPColor.inkDim)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(CPColor.line, lineWidth: 1))
                HStack(spacing: 0) {
                    metric("CPU", sample.map { String(format: "%.0f%%", $0.cpu) } ?? "—")
                    metric("Memory", sample.map { String(format: "%.1f GB", $0.ramMB / 1024) } ?? "—")
                    metric("Uptime", PerformanceChart.uptime(since: runtime.snapshot.startedAt, now: Date()))
                    metric("Online", "\(runtime.online.count)")
                }
            } else {
                Text(status == .crashed ? "Crashed. Open it to see the console." : "Not running")
                    .font(.system(size: 12)).foregroundStyle(status == .crashed ? CPColor.bad : CPColor.inkFaint)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            }

            HStack(spacing: 8) {
                Button(running ? "Stop" : "Start", action: onToggle).cpButton(running ? .secondary : .primary, size: .sm)
                Button("Open", action: onOpen).cpButton(.ghost, size: .sm)
                Spacer()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(hovering ? CPColor.surface2 : CPColor.surface, in: RoundedRectangle(cornerRadius: CPRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CPRadius.lg, style: .continuous).strokeBorder(isSelected ? CPColor.accent : CPColor.line))
        .contentShape(RoundedRectangle(cornerRadius: CPRadius.lg, style: .continuous))
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .task(id: runtime.snapshot.pid) { await poll() }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11)).foregroundStyle(CPColor.inkFaint)
            Text(value).font(.system(size: 13, design: .monospaced)).foregroundStyle(CPColor.ink).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func poll() async {
        while !Task.isCancelled {
            if running, let pid = runtime.snapshot.pid {
                let (ram, cpu) = PerfSampler.processSample(pid: pid)
                sample = ram.map { (Double($0), cpu ?? 0) }
            } else { sample = nil }
            try? await Task.sleep(for: .seconds(3))
        }
    }
}
