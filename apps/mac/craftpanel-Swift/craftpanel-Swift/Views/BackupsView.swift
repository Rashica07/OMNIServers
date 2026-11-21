import SwiftUI

/// Zip Backups / Time Machine, one segmented control instead of two
/// stacked cards. Matches the real Tauri `BackupsPanel.tsx` exactly —
/// resource pack config lives in the Add-ons tab there (`BrowsePanel.tsx`
/// via `ResourcePackSection`), not here; an earlier version of this view
/// put it here instead, a real "doesn't match the main app" gap now
/// closed by moving it to `AddonsView`.
///
/// Heavy work (zipping, hard-linking) runs off the main actor via
/// `Task.detached`, capturing only plain Sendable values (paths,
/// strings) — never `self` — so a multi-GB world doesn't freeze the UI
/// while it backs up. Deliberate simplification versus the Tauri app:
/// granular "compressing 200/500 files" progress text isn't streamed
/// here, just a busy spinner — the Rust side gets that for free from
/// Tauri's event system; wiring an equivalent here is real scope worth
/// revisiting later, not dropped by oversight.
struct BackupsView: View {
    let server: ServerRecord
    @Environment(ProcessManager.self) private var processes

    private enum Tab: String, CaseIterable { case zip = "Zip Backups", timeMachine = "Time Machine" }
    @State private var tab: Tab = .zip

    var body: some View {
        VStack(spacing: 0) {
            CPSegmentedPicker(selection: $tab, labels: Tab.allCases.map { ($0, $0.rawValue) })
                .frame(maxWidth: 300)
                .padding(10)

            Divider()

            Group {
                switch tab {
                case .zip: ZipBackupsTab(server: server, isRunning: processes.isRunning(server.id))
                case .timeMachine: TimeMachineTab(server: server, isRunning: processes.isRunning(server.id))
                }
            }
        }
        .navigationTitle("Backups")
    }
}

// MARK: - Zip Backups

private struct ZipBackupsTab: View {
    @Environment(ProcessManager.self) private var processes
    let server: ServerRecord
    let isRunning: Bool

    @State private var backups: [Backup] = []
    @State private var newLabel = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var noticeText: String?
    @State private var pendingImport: PendingImport?

    /// A zip (and optional .json) the user picked, waiting for their OK.
    private struct PendingImport: Identifiable {
        let id = UUID()
        let zip: URL
        let json: URL?
        let summary: String
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if isRunning {
                    CPBanner(tone: .info, message: "Restoring requires the server to be stopped first.")
                }
                if let errorText {
                    CPBanner(tone: .bad, message: errorText)
                }
                if let noticeText {
                    CPBanner(tone: .info, message: noticeText)
                }
                SettingsCard(title: "Back up now", symbol: "archivebox") {
                    HStack {
                        TextField("Label (optional)", text: $newLabel)
                            .textFieldStyle(.roundedBorder)
                        Button(busy ? "Backing up…" : "Back Up Now") {
                            Task { await backupNow() }
                        }
                        .cpButton(.primary)
                        .disabled(busy)
                    }
                }
                SmartRetentionCard()
                SettingsCard(title: "Backup from a friend?", symbol: "square.and.arrow.down",
                             description: "Add a backup someone else made — their .zip and .json — to this server's list, then restore it. Nothing changes on this server until you press Restore.") {
                    Button("Import Backup…") { chooseImport() }
                        .cpButton(.secondary)
                        .disabled(busy)
                }
                if backups.isEmpty {
                    CPStateBlock(state: .empty, title: "No backups yet.", compact: true)
                } else {
                    VStack(spacing: 6) {
                        ForEach(backups) { b in
                            BackupRow(backup: b, disabled: busy || isRunning, onRestore: {
                                Task { await restore(b.id) }
                            }, onDelete: {
                                Task { await delete(b.id) }
                            })
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(CPColor.bg)
        .task(id: server.id) { reload() }
        .alert("Import this backup?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }), presenting: pendingImport) { p in
            Button("Import") { Task { await runImport(p) } }
            Button("Cancel", role: .cancel) {}
        } message: { p in
            Text(p.summary)
        }
    }

    private func reload() {
        backups = BackupManager.list(dir: URL(fileURLWithPath: server.path))
    }

    /// Pick the backup's .zip (and its .json if you have it — one next to the zip is found automatically).
    private func chooseImport() {
        errorText = nil; noticeText = nil
        let panel = NSOpenPanel()
        panel.title = "Choose the backup .zip (and its .json if you have it)"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        let picked = panel.urls
        guard let zip = picked.first(where: { $0.pathExtension.lowercased() == "zip" }) else {
            errorText = "Pick the backup's .zip file."
            return
        }
        let json = picked.first(where: { $0.pathExtension.lowercased() == "json" }) ?? BackupManager.siblingJSON(of: zip)
        do {
            let info = try BackupManager.inspectZip(zip)
            if info.unsafeEntry != nil || !info.looksLikeAServer {
                // importBackup explains exactly why
                _ = try BackupManager.importBackup(dir: URL(fileURLWithPath: server.path), zip: zip, json: json, progress: { _ in })
                return
            }
            let what = [info.hasWorld ? "a world" : nil, info.mods > 0 ? "\(info.mods) mods" : nil,
                        info.plugins > 0 ? "\(info.plugins) plugins" : nil, info.hasServerProperties ? "server settings" : nil]
                .compactMap { $0 }.joined(separator: ", ")
            let size = ByteCountFormatter.string(fromByteCount: Int64(info.uncompressedBytes), countStyle: .file)
            pendingImport = PendingImport(zip: zip, json: json, summary:
                "\(zip.lastPathComponent): \(info.entries) files, \(size) unpacked, with \(what). It's added to your list; nothing changes on this server until you press Restore." + (json == nil ? " There's no .json with it, so it will be dated by the file." : ""))
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func runImport(_ p: PendingImport) async {
        busy = true; errorText = nil; noticeText = nil
        defer { busy = false }
        let dirPath = server.path
        do {
            let meta = try await Task.detached(priority: .userInitiated) {
                try BackupManager.importBackup(dir: URL(fileURLWithPath: dirPath), zip: p.zip, json: p.json, progress: { _ in })
            }.value
            noticeText = meta.verified == false
                ? "Imported, but it may be damaged — check it before restoring."
                : "Imported and verified. Press Restore next to it to put it on this server (your current files are backed up first)."
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func backupNow() async {
        busy = true; errorText = nil
        defer { busy = false }
        let dirPath = server.path
        let label = newLabel
        do {
            // Flush + pause autosave while the world is copied (no torn region files).
            _ = try await processes.withSavesPaused(server.id) {
                try await Task.detached(priority: .userInitiated) {
                    let dir = URL(fileURLWithPath: dirPath)
                    _ = try BackupManager.backupNow(dir: dir, label: label, trigger: "manual", progress: { _ in })
                    BackupManager.applyRetention(dir: dir)
                }.value
            }
            newLabel = ""
            reload()
            Toasts.shared.show("Backup saved", symbol: "externaldrive.fill.badge.checkmark")
        } catch {
            errorText = error.localizedDescription
            Toasts.shared.error("Backup failed", detail: error.localizedDescription)
        }
    }

    private func restore(_ id: String) async {
        busy = true; errorText = nil
        defer { busy = false }
        let dirPath = server.path
        do {
            try await Task.detached(priority: .userInitiated) {
                try BackupManager.restore(dir: URL(fileURLWithPath: dirPath), id: id, progress: { _ in })
            }.value
            reload()
            Toasts.shared.show("Backup restored", symbol: "arrow.counterclockwise.circle.fill")
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func delete(_ id: String) async {
        do {
            try BackupManager.delete(dir: URL(fileURLWithPath: server.path), id: id)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct BackupRow: View {
    let backup: Backup
    let disabled: Bool
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Date(timeIntervalSince1970: TimeInterval(backup.createdAt)).formatted(date: .abbreviated, time: .shortened))
                        .font(.callout.weight(.medium))
                    TriggerBadge(trigger: backup.trigger)
                }
                HStack(spacing: 6) {
                    if let label = backup.label { Text(label) }
                    Text(ByteCountFormatter.string(fromByteCount: Int64(backup.sizeBytes), countStyle: .file))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore", action: onRestore).cpButton(.secondary, size: .sm).disabled(disabled)
            Button("Delete", action: onDelete).cpButton(.danger, size: .sm).disabled(disabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(CPColor.surface)
        .overlay(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous).strokeBorder(CPColor.lineSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous))
    }
}

private struct TriggerBadge: View {
    let trigger: String
    var body: some View {
        Text(trigger.replacingOccurrences(of: "-", with: " ").capitalized)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.secondary.opacity(0.15), in: Capsule())
    }
}

// MARK: - Time Machine

private struct TimeMachineTab: View {
    @Environment(ProcessManager.self) private var processes
    let server: ServerRecord
    let isRunning: Bool

    @State private var snapshots: [Snapshot] = []
    @State private var busy = false
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if isRunning {
                    CPBanner(tone: .info, message: "Restoring requires the server to be stopped first.")
                }
                if let errorText {
                    CPBanner(tone: .bad, message: errorText)
                }
                SettingsCard(title: "Time Machine", symbol: "clock.arrow.circlepath",
                             description: "Snapshots of the world as it is right now. Unchanged files cost nothing, so this can run often — and a restore swaps only the world; your mods and settings stay.") {
                    HStack {
                        Button(busy ? "Snapshotting…" : "Snapshot Now") {
                            Task { await snapshotNow() }
                        }
                        .cpButton(.primary)
                        .disabled(busy)
                    }
                }
                if snapshots.isEmpty {
                    CPStateBlock(state: .empty, title: "No snapshots yet.", compact: true)
                } else {
                    VStack(spacing: 6) {
                        ForEach(snapshots) { s in
                            SnapshotRow(snapshot: s, disabled: busy || isRunning, onRestore: {
                                Task { await restore(s.id) }
                            }, onDelete: {
                                Task { await delete(s.id) }
                            })
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(CPColor.bg)
        .task(id: server.id) { reload() }
    }

    private func reload() {
        snapshots = SnapshotManager.list(dir: URL(fileURLWithPath: server.path))
    }

    private func snapshotNow() async {
        busy = true; errorText = nil
        defer { busy = false }
        let dirPath = server.path
        do {
            _ = try await processes.withSavesPaused(server.id) {
                try await Task.detached(priority: .userInitiated) {
                    try SnapshotManager.snapshotNow(dir: URL(fileURLWithPath: dirPath), trigger: "manual", progress: { _ in })
                }.value
            }
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func restore(_ id: String) async {
        busy = true; errorText = nil
        defer { busy = false }
        let dirPath = server.path
        do {
            try await Task.detached(priority: .userInitiated) {
                try SnapshotManager.restore(dir: URL(fileURLWithPath: dirPath), id: id, progress: { _ in })
            }.value
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func delete(_ id: String) async {
        do {
            try SnapshotManager.delete(dir: URL(fileURLWithPath: server.path), id: id)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct SnapshotRow: View {
    let snapshot: Snapshot
    let disabled: Bool
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(Date(timeIntervalSince1970: TimeInterval(snapshot.createdAt)).formatted(date: .abbreviated, time: .shortened))
                        .font(.callout.weight(.medium))
                    TriggerBadge(trigger: snapshot.trigger)
                    if !snapshot.isWorld {
                        Badge(text: "whole server", tone: .warn, symbol: nil)
                            .help("Taken by an older version: it holds the whole server folder, not just the world.")
                    }
                }
                Text("\(snapshot.fileCount) files · \(snapshot.newBytes == 0 ? "0 KB (linked)" : ByteCountFormatter.string(fromByteCount: Int64(snapshot.newBytes), countStyle: .file) + " new")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restore", action: onRestore).cpButton(.secondary, size: .sm).disabled(disabled)
            Button("Delete", action: onDelete).cpButton(.danger, size: .sm).disabled(disabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(CPColor.surface)
        .overlay(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous).strokeBorder(CPColor.lineSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous))
    }
}



/// "Keep recent, thin older to 1/day" for zip backups (global,
/// like Tauri's `set_backups_tiered`).
private struct SmartRetentionCard: View {
    @State private var tiered = AppDefaults.backupTiered

    var body: some View {
        SettingsCard(title: "Smart retention", symbol: "calendar.badge.clock",
                     description: "Keep everything recent, then thin older backups to one per day. Replaces the plain keep-newest limit while on.") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Spacer()
                    CPToggle(isOn: Binding(get: { tiered != nil }, set: { tiered = $0 ? .init(recentHours: 24, dailyDays: 30) : nil }))
                }
                if let t = tiered {
                    Stepper("Keep everything from the last \(t.recentHours) hours", value: Binding(
                        get: { t.recentHours }, set: { tiered?.recentHours = max(1, min(720, $0)) }), in: 1...720)
                    Stepper("then one per day for \(t.dailyDays) days", value: Binding(
                        get: { t.dailyDays }, set: { tiered?.dailyDays = max(1, min(365, $0)) }), in: 1...365)
                }
            }
            .font(.system(size: 12))
            .onChange(of: tiered) { _, v in AppDefaults.backupTiered = v }
        }
    }
}
