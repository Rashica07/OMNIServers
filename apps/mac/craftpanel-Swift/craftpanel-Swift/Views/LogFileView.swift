import SwiftUI

/// Tail of `logs/latest.log`. Works for any server -- managed,
/// reattached, or one started outside OMNIServers entirely -- which is
/// why it's a peer of the live console rather than a fallback buried in
/// a menu. Direct port of `LogView.tsx`, including its sticky-scroll
/// behavior (only follows new output if you were already near the
/// bottom) and its "snapshot" notice when the server isn't running.
struct LogFileView: View {
    let record: ServerRecord
    let isRunning: Bool

    @State private var text: String?
    @State private var errorText: String?
    @State private var busy = false
    @State private var stickToBottom = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !findings.isEmpty { findingsPanel }
            content
            if !isRunning {
                snapshotNotice
            }
        }
        .task(id: "\(record.id)-\(isRunning)") {
            await fetchTail()
            guard isRunning else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { return }
                await fetchTail()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .foregroundStyle(CPColor.inkFaint)
            Text("logs/latest.log")
                .font(CPFont.display(12, weight: .semibold))
                .foregroundStyle(CPColor.ink)
            if isRunning {
                Label("auto-refreshing", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(CPColor.ok)
            }
            Spacer()
            Text("last 500 lines")
                .font(.caption2)
                .foregroundStyle(CPColor.inkFaint)
            IconButton(systemName: "doc.on.doc", size: 26, help: "Copy the log to share it") {
                Toasts.shared.copy(text ?? "", what: "Log")
            }
            IconButton(systemName: "arrow.clockwise", size: 26, help: "Refresh now") {
                Task { await fetchTail(showSpinner: true) }
            }
            .opacity(busy ? 0.6 : 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(CPColor.surface)
    }

    private var findings: [LogFinding] { LogAnalyzer.analyze(text ?? "") }

    private var findingsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(findings) { f in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: f.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(f.severity == .error ? CPColor.bad : CPColor.warn)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(CPColor.ink)
                        Text(f.advice).font(.caption).foregroundStyle(CPColor.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CPColor.surface2)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private var content: some View {
        if let errorText {
            VStack(spacing: 8) {
                Text("Can't read the log")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(CPColor.ink)
                Text("The server hasn't written logs/latest.log yet, or the folder moved.")
                    .font(.caption)
                    .foregroundStyle(CPColor.inkFaint)
                Text(errorText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(CPColor.inkGhost)
                Button("Retry") { Task { await fetchTail(showSpinner: true) } }
                    .cpButton(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CPColor.console)
        } else if let text {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(text.isEmpty ? "(the log file is empty)" : text)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(CPColor.inkDim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                        .id("bottom")
                }
                .background(CPColor.console)
                // Tracks whether the visible area is already near the
                // bottom, so a fresh tail only auto-scrolls if the user
                // hasn't scrolled up to read older lines -- matches the
                // web source's `stick.current` ref exactly, just backed
                // by the real geometry-change API instead of a manual
                // onScroll handler.
                .onScrollGeometryChange(for: ScrollFollow.self) { geo in
                    ScrollFollow(offsetY: geo.contentOffset.y,
                                 nearBottom: geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 40)
                } action: { old, new in
                    // Same rule as the live console: only an upward scroll
                    // by you stops following.
                    if new.nearBottom { stickToBottom = true } else if new.offsetY < old.offsetY - 1 { stickToBottom = false }
                }
                .onChange(of: text) {
                    if stickToBottom { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(CPColor.console)
        }
    }

    private var snapshotNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
            Text("The server isn't running, so this is a snapshot.")
            Spacer()
            Button("Refresh") { Task { await fetchTail(showSpinner: true) } }
                .buttonStyle(.plain)
        }
        .font(.caption2)
        .foregroundStyle(CPColor.inkFaint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(CPColor.surface2)
    }

    private func fetchTail(showSpinner: Bool = false) async {
        if showSpinner { busy = true }
        defer { busy = false }
        do {
            let dir = URL(fileURLWithPath: record.path)
            text = try await Task.detached(priority: .userInitiated) { try ServerFileBrowser.tail(root: dir, rel: nil, maxLines: 500) }.value
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}
