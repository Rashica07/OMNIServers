import SwiftUI

/// Live console: styled scrollback + a command field with real ↑/↓ history.
struct ConsoleView: View {
    let record: ServerRecord
    @Bindable var runtime: ServerRuntime
    /// Bubbles the crash banner's "Find X" action up to `ServerDetailShell`,
    /// which owns tab switching — jumps to Add-ons already searching for
    /// the missing dependency.
    var onFindDependency: (String) -> Void = { _ in }

    @State private var command = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int?
    @State private var autoScroll = true
    @State private var filter = ""
    @State private var showFilter = false
    private enum Mode: String, CaseIterable { case live = "Live console", log = "Log file" }
    @State private var mode: Mode = .live

    @State private var crash: CrashReport?
    @State private var crashDismissed = false
    @State private var suspectDisabled = false
    @State private var disablingSuspect = false

    private var filteredLines: [LogLine] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !f.isEmpty else { return runtime.lines }
        return runtime.lines.filter { $0.text.lowercased().contains(f) }
    }

    private var errorCount: Int {
        filteredLines.count { ConsoleLineStyle.severity(of: $0.text, stream: $0.stream) == .error }
    }

    var body: some View {
        VStack(spacing: 0) {
            if runtime.isRunning {
                HealthStripView(record: record, pid: runtime.snapshot.pid, isRunning: runtime.isRunning)
                    .padding(10)
            }
            if runtime.snapshot.needsEULA {
                eulaBanner
            }
            if runtime.snapshot.reattached {
                reattachedBanner
            }
            if runtime.snapshot.status == .crashed, !runtime.snapshot.needsEULA, !crashDismissed {
                crashBanner
            }

            CPSegmentedPicker(selection: $mode, labels: [(.live, "Live console"), (.log, "Log file")])
                .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if mode == .log {
                LogFileView(record: record, isRunning: runtime.isRunning)
            } else {
                liveConsole
            }
        }
        .task(id: "\(record.id)-\(runtime.snapshot.status == .crashed)") {
            guard runtime.snapshot.status == .crashed else { return }
            crash = CrashReports.latest(serverDir: URL(fileURLWithPath: record.path))
            crashDismissed = false
            suspectDisabled = false
        }
    }

    // MARK: - Crash banner

    private var crashBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(runtime.snapshot.exitCode.map { "Server crashed (exit code \($0))" } ?? "Server crashed")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(CPColor.ink)
                    if let headline = crash?.headline {
                        Text(headline)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(CPColor.inkFaint)
                            .lineLimit(2)
                    }
                }
                Spacer()
                IconButton(systemName: "xmark", size: 22) {
                    crashDismissed = true
                }
            }
            HStack(spacing: 8) {
                if ModsManager.loaderUsesMods(record.serverType),
                   let suspect = crash?.suspect, suspect.hasSuffix(".jar") {
                    Button(suspectDisabled ? "Disabled" : (disablingSuspect ? "Disabling…" : "Disable it")) {
                        Task { await disableSuspect(suspect) }
                    }
                    .disabled(disablingSuspect || suspectDisabled)
                }
                if let dep = crash?.missingDependency {
                    Button("Find \(dep.modID)") {
                        onFindDependency(dep.modID)
                    }
                }
                Button("Start again") {
                    do { try runtime.start(record: record) }
                    catch { runtime.push(.system, error.localizedDescription) }
                }
            }
        }
        .padding(10)
        .background(CPColor.bad.opacity(0.12))
    }

    private func disableSuspect(_ jarName: String) async {
        disablingSuspect = true
        defer { disablingSuspect = false }
        do {
            try ModsManager.setEnabled(serverDir: URL(fileURLWithPath: record.path), name: jarName, enable: false)
            suspectDisabled = true
        } catch {
            runtime.push(.system, "Couldn't disable \(jarName): \(error.localizedDescription)")
        }
    }

    private var liveConsole: some View {
        VStack(spacing: 0) {
            consoleToolbar
            Divider().overlay(CPColor.lineSoft)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if filteredLines.isEmpty {
                            emptyState
                        } else {
                            ForEach(filteredLines) { line in
                                Text(ConsoleLineStyle.attributed(line))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                    .id(line.id)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(minHeight: filteredLines.isEmpty ? 200 : nil)
                }
                // The real `.cp-well` console treatment: near-black,
                // slightly cooler than the app canvas, with a faint warm
                // bloom top-center so a wall of monospace text doesn't
                // read as a flat pit.
                .background(
                    CPColor.console.overlay(
                        RadialGradient(
                            colors: [Color.white.opacity(0.02), .clear],
                            center: .top, startRadius: 0, endRadius: 320
                        )
                    )
                )
                // Tracks whether the visible area is already near the
                // bottom, so a fresh line only auto-scrolls if the user
                // hasn't scrolled up to read older lines — real geometry
                // tracking, not the always-true placeholder this had
                // before (the same class of dead-scroll-tracking bug
                // `LogFileView` caught and fixed for the log-file mode).
                // Following stops only when *you* scroll up (the offset
                // moves up), never because new lines grew the content
                // before the follow-scroll landed — that race is what
                // used to switch following off right after "Jump to
                // latest". Reaching the bottom again resumes it.
                .onScrollGeometryChange(for: ScrollFollow.self) { geo in
                    ScrollFollow(offsetY: geo.contentOffset.y,
                                 nearBottom: geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 40)
                } action: { old, new in
                    if new.nearBottom { autoScroll = true } else if new.offsetY < old.offsetY - 1 { autoScroll = false }
                }
                .onChange(of: filteredLines.last?.id) { _, newValue in
                    guard autoScroll, let newValue else { return }
                    proxy.scrollTo(newValue, anchor: .bottom)
                }
                .onAppear {
                    if let last = filteredLines.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !autoScroll {
                        Button {
                            autoScroll = true
                            if let last = filteredLines.last?.id {
                                withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                            }
                        } label: {
                            Label("Jump to latest", systemImage: "arrow.down.to.line")
                        }
                        .cpButton(.primary, size: .sm)
                        .padding(10)
                    }
                }
            }

            Divider()
            commandField
        }
    }

    private var consoleToolbar: some View {
        HStack(spacing: 8) {
            Label("Console", systemImage: "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(CPColor.ink)

            if errorCount > 0 {
                Text("\(errorCount) error\(errorCount > 1 ? "s" : "")")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(CPColor.bad.opacity(0.15))
                    .foregroundStyle(CPColor.bad)
                    .clipShape(Capsule())
            }

            Text("\(filteredLines.count) line\(filteredLines.count == 1 ? "" : "s")\(filter.isEmpty ? "" : " of \(runtime.lines.count)")")
                .font(.system(size: 10))
                .foregroundStyle(CPColor.inkFaint)
                .monospacedDigit()

            Spacer()

            if showFilter {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(CPColor.inkFaint)
                    TextField("Filter lines…", text: $filter)
                        .textFieldStyle(.plain)
                        .font(.caption2)
                        .onKeyPress(.escape) { filter = ""; showFilter = false; return .handled }
                    IconButton(systemName: "xmark.circle.fill", size: 22) {
                        filter = ""; showFilter = false
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .frame(width: 200)
                .background(CPColor.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            } else {
                IconButton(systemName: "magnifyingglass", size: 26, help: "Filter lines") {
                    showFilter = true
                }
            }

            IconButton(systemName: "trash", size: 26, help: "Clear this view (doesn't touch the server or its log file)") {
                runtime.clearConsole()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(CPColor.surface)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 22))
                .foregroundStyle(CPColor.inkGhost)
            Text(emptyMessage)
                .font(.caption)
                .foregroundStyle(CPColor.inkGhost)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var emptyMessage: String {
        if !filter.isEmpty { return "No lines match that filter." }
        return runtime.isRunning ? "Waiting for the server to say something…" : "Start the server and its output shows up here."
    }

    private var eulaBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(CPColor.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text("Minecraft's EULA hasn't been accepted")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(CPColor.ink)
                Text("The server won't start until you accept it.")
                    .font(.caption)
                    .foregroundStyle(CPColor.inkFaint)
            }
            Spacer()
            Button("Accept EULA") {
                try? runtime.acceptEULA(record: record)
            }
            .cpButton(.primary, size: .sm)
        }
        .padding(10)
        .background(CPColor.warn.opacity(0.12))
    }

    private var reattachedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(CPColor.inkFaint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Reattached after a restart")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(CPColor.ink)
                Text("Live console output before now wasn't captured. Stop and Players still work.")
                    .font(.caption)
                    .foregroundStyle(CPColor.inkFaint)
            }
            Spacer()
        }
        .padding(10)
        .background(CPColor.surface3)
    }

    private var commandField: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
            TextField(runtime.snapshot.reattached ? "Unavailable — reattached, no stdin" : "Send a command…", text: $command)
                .textFieldStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .disabled(!runtime.isRunning || runtime.snapshot.reattached)
                .onSubmit(send)
                // Real ↑/↓ history via .onKeyPress — the native equivalent
                // of the web app's manual keydown handling in ConsoleView.tsx.
                .onKeyPress(.upArrow) {
                    recallHistory(offset: -1)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    recallHistory(offset: 1)
                    return .handled
                }
            if !history.isEmpty {
                Text("↑ history")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(CPColor.surface)
    }

    private func send() {
        let text = command.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, runtime.isRunning else { return }
        do {
            try runtime.writeStdin(text)
            runtime.push(.system, "> \(text)")
            history.append(text)
            if history.count > 200 { history.removeFirst(history.count - 200) }
            historyIndex = nil
            command = ""
        } catch {
            runtime.push(.system, error.localizedDescription)
        }
    }

    private func recallHistory(offset: Int) {
        guard !history.isEmpty else { return }
        let next: Int
        switch historyIndex {
        case nil:
            next = offset < 0 ? history.count - 1 : history.count
        case .some(let cur):
            next = cur + offset
        }
        if next < 0 {
            historyIndex = 0
        } else if next >= history.count {
            historyIndex = nil
            command = ""
            return
        } else {
            historyIndex = next
        }
        if let i = historyIndex { command = history[i] }
    }
}

/// Small status chip, reused by the console toolbar and the sidebar.
struct StatusPill: View {
    let status: ServerStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption)
        }
        .foregroundStyle(.secondary)
    }

    private var label: String {
        switch status {
        case .starting: "Starting"
        case .running: "Running"
        case .stopping: "Stopping"
        case .stopped: "Stopped"
        case .crashed: "Crashed"
        case .unknown: "Unknown"
        }
    }

    private var color: Color {
        switch status {
        case .running: CPColor.ok
        case .starting, .stopping: CPColor.warn
        case .crashed: CPColor.bad
        case .stopped, .unknown: CPColor.inkGhost
        }
    }
}

/// Scroll position facts for the console/log follow logic.
struct ScrollFollow: Equatable {
    var offsetY: CGFloat
    var nearBottom: Bool
}
