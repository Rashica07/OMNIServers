//
//  craftpanel_SwiftApp.swift
//  craftpanel-Swift
//

import SwiftUI
import SwiftData
import UserNotifications

/// Owns app-lifetime concerns SwiftUI's `App` has no hook for: ignoring
/// SIGPIPE (a write to a just-died server's stdin must be an error, not a
/// crash) and stopping servers/tunnels before the app actually quits.
/// True when this process is the unit-test host. The app then starts no
/// services (no adopt of real servers, scheduler, Remote API, Sparkle) and
/// never touches real servers on quit — parallel test runners used to launch
/// full OMNIServers instances against the user's real server list.
let isRunningUnitTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    || NSClassFromString("XCTestCase") != nil

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// One ProcessManager for the whole app — the Swift equivalent of the
    /// single `ProcessManager` living in Tauri state.
    let processes = ProcessManager()
    nonisolated(unsafe) static weak var shared: AppDelegate?

    func applicationWillFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        AppDelegate.shared = self
        if !isRunningUnitTests { UNUserNotificationCenter.current().delegate = NotificationRouter.shared }
    }

    /// An update chosen with "When I quit" goes in once this process is gone.
    func applicationWillTerminate(_ notification: Notification) {
        if isRunningUnitTests { return }
        MainActor.assumeIsolated { UpdateFlow.shared.applyOnQuit() }
    }

    /// Graceful shutdown: send `stop` to every running server, wait for
    /// them (bounded), force-kill stragglers, then let the app exit. Never
    /// leaves an orphaned JVM holding the world lock and port 25565.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isRunningUnitTests { return .terminateNow }
        TunnelManager.shared.stopAll()
        Task { @MainActor in await PlayitAgent.shared.shutdown() }
        // "Keep servers running when I quit": leave them; next launch re-adopts them.
        guard processes.anyRunning, !AppDefaults.keepServersOnQuit else { return .terminateNow }
        processes.shutdownAll()
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(TimeInterval(ServerRuntime.gracefulStopSeconds + 5))
            while processes.anyRunning, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(250))
            }
            processes.forceKillAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct craftpanel_SwiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var processes: ProcessManager { appDelegate.processes }
    @State private var scheduler: Scheduler?
    /// The menu-bar item keeps redrawing while idle, so it can be switched off (Settings, or `defaults write`).
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    /// `nil` while still checking, matching `App.tsx`'s own
    /// undefined/null/boolean three-state `locked`.
    @State private var unlocked: Bool = !AppLock.shared.isSet

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            ServerRecord.self,
            MetricSample.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // Unmigratable store (schema change, corruption): move it aside
            // instead of crashing at launch forever. Server folders on disk
            // are untouched; only the app's index of them is reset.
            let url = modelConfiguration.url
            let aside = url.deletingLastPathComponent()
                .appending(path: "default.store.broken-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: url, to: aside)
            if let c = try? ModelContainer(for: schema, configurations: [modelConfiguration]) { return c }
            // Last resort: run with an in-memory store rather than not at all.
            let mem = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            return try! ModelContainer(for: schema, configurations: [mem])
        }
    }()

    @State private var themes = ThemeStore.shared

    var body: some Scene {
        WindowGroup(id: "main") {
            Group {
                if isRunningUnitTests {
                    Color.clear
                } else if unlocked {
                    ServerListView()
                        .environment(processes)
                        .overlay(alignment: .topTrailing) { ToastOverlay() }
                } else {
                    LockScreenView { unlocked = true }
                }
            }
                // Re-render everything when the theme changes: CPColor reads
                // the active palette, so a new identity picks it up.
                .id(themes.theme)
                .preferredColorScheme(themes.theme.palette.isLight ? .light : .dark)
                .tint(CPColor.accent)
                .buttonStyle(CPButtonStyle.appDefault)
                .background(CPColor.bg)
                .background(WindowChrome())
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    guard !isRunningUnitTests else { return }
                    // The automation engine (crash-restart, daily
                    // restart, timed commands, backup/snapshot triggers)
                    // and "stay awake on power" both start once here,
                    // mirroring `lib.rs`'s own launch-time setup.
                    if scheduler == nil {
                        let s = Scheduler(container: sharedModelContainer, processes: processes)
                        s.start()
                        scheduler = s
                    }
                    PlayitCoordinator.shared.configure(container: sharedModelContainer)
                    MetricsSampler.shared.configure(container: sharedModelContainer, processes: processes)
                    MetricsSampler.shared.start()
                    PowerKeeper.shared.setEnabled(AppDefaults.stayAwakeOnPower)
                    RemoteAPIServer.shared.configure(container: sharedModelContainer, processes: processes)
                }
        }
        .modelContainer(sharedModelContainer)
        .windowStyle(.hiddenTitleBar)
        // Matches `tauri.conf.json`'s window exactly (1200×800 default,
        // 900×600 floor via the root view's `.frame(minWidth:minHeight:)`
        // above).
        .defaultSize(width: 1200, height: 800)
        .commands { CraftPanelCommands(processes: processes, container: sharedModelContainer) }

        // Standard macOS Settings window — ⌘, from anywhere.
        Settings {
            AppSettingsView(showsHeader: false)
                .buttonStyle(CPButtonStyle.appDefault)
                .id(themes.theme)
                .preferredColorScheme(themes.theme.palette.isLight ? .light : .dark)
                .tint(CPColor.accent)
                .frame(width: 720, height: 620)
                .environment(processes)
                .modelContainer(sharedModelContainer)
        }

        // Tray equivalent: servers keep running with the window closed, and
        // this is where you see and control them.
        MenuBarExtra(isInserted: Binding(get: { showMenuBarIcon && !isRunningUnitTests }, set: { showMenuBarIcon = $0 })) {
            MenuBarContent()
                .environment(processes)
                .modelContainer(sharedModelContainer)
        } label: {
            Image("MenuBarIcon")
        }
    }
}
