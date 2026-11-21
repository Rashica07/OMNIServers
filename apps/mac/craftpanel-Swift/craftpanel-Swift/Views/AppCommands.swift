import SwiftUI
import SwiftData
import AppKit

/// The menu bar — the native counterpart of Tauri's command palette and
/// header buttons. Server commands act on the server selected in the main
/// window.
struct CraftPanelCommands: Commands {
    let processes: ProcessManager
    let container: ModelContainer
    @Environment(\.openWindow) private var openWindow

    private var router: AppRouter { AppRouter.shared }

    private var selected: ServerRecord? {
        guard let id = router.selectedServerID else { return nil }
        let d = FetchDescriptor<ServerRecord>(predicate: #Predicate { $0.id == id })
        return try? container.mainContext.fetch(d).first
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Server…") { showMain(); router.showCreate = true }
                .keyboardShortcut("n")
            Button("Add Existing Server Folder…") { showMain(); router.showAddFolder = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }

        CommandGroup(after: .sidebar) {
            Button("Overview") { showMain(); router.destination = .overview }
                .keyboardShortcut("0")
            Button("Command Palette…") { showMain(); router.showPalette = true }
                .keyboardShortcut("k")
            Divider()
        }

        CommandMenu("Server") {
            let s = selected
            let running = s.map { processes.isRunning($0.id) } ?? false
            Button("Start") { if let s { try? processes.start(s) } }
                .keyboardShortcut("r")
                .disabled(s == nil || running)
            Button("Stop") { if let s { try? processes.stop(s.id) } }
                .keyboardShortcut(".")
                .disabled(!running)
            Button("Restart") { if let s { restart(s) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!running)
            Button("Force Kill") { if let s { try? processes.forceKill(s.id) } }
                .keyboardShortcut(".", modifiers: [.command, .option])
                .disabled(!running)
            Divider()
            ForEach([ServerSection.console, .chat, .players, .map, .settings, .backups, .files], id: \.self) { section in
                Button(section.label) { if let s { showMain(); router.destination = .server(s.id, section) } }
                    .disabled(s == nil)
            }
            Divider()
            Button("Show in Finder") { if let s { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.path)]) } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(s == nil)
        }

        CommandGroup(replacing: .help) {
            Button("OMNIServers Help & Tutorial") { showMain(); router.helpContext = "overview"; router.showHelp = true }
                .keyboardShortcut("?", modifiers: .command)
        }
    }

    private func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { openWindow(id: "main") }
    }

    private func restart(_ s: ServerRecord) {
        let id = s.id
        try? processes.stop(id)
        Task { @MainActor in
            for _ in 0..<120 where processes.isRunning(id) { try? await Task.sleep(for: .milliseconds(500)) }
            let d = FetchDescriptor<ServerRecord>(predicate: #Predicate { $0.id == id })
            if let rec = try? container.mainContext.fetch(d).first { try? processes.start(rec) }
        }
    }
}

/// Menu-bar extra contents: every server with its status and a start/stop
/// toggle, plus Open / Quit — the Tauri tray menu, natively.
struct MenuBarContent: View {
    @Environment(ProcessManager.self) private var processes
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \ServerRecord.name) private var servers: [ServerRecord]

    var body: some View {
        let running = servers.filter { processes.isRunning($0.id) }.count
        let players = servers.reduce(0) { $0 + processes.runtime(for: $1.id).online.count }
        Text(running == 0 ? "No servers running" : "\(running) running · \(players) player\(players == 1 ? "" : "s") online")
        Divider()
        ForEach(servers) { s in
            let status = processes.runtime(for: s.id).snapshot.status
            let online = processes.runtime(for: s.id).online
            Menu("\(dot(status)) \(s.name)\(online.isEmpty ? "" : " — \(online.count) online")") {
                if !online.isEmpty {
                    ForEach(online, id: \.self) { Text($0) }
                    Divider()
                }
                if processes.isRunning(s.id) {
                    Button("Stop") { try? processes.stop(s.id) }
                } else {
                    Button("Start") { try? processes.start(s) }
                }
                Button("Open") { open(); AppRouter.shared.destination = .server(s.id, nil) }
            }
        }
        if !servers.isEmpty { Divider() }
        Button("Open OMNIServers") { open() }
        SettingsLink { Text("Settings…") }
        Divider()
        Button("Quit OMNIServers") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func dot(_ s: ServerStatus) -> String {
        switch s {
        case .running: "●"
        case .starting, .stopping: "◐"
        case .crashed: "✕"
        case .stopped, .unknown: "○"
        }
    }

    private func open() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.canBecomeMain }) { w.makeKeyAndOrderFront(nil) } else { openWindow(id: "main") }
    }
}
