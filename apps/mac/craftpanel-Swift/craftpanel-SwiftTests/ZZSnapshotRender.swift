import XCTest
import SwiftUI
import SwiftData
@testable import craftpanel_Swift

/// Not an assertion test: renders key screens to PNG for visual review.
/// Only runs when CP_SNAPSHOT_DIR is set.
@MainActor
final class ZZSnapshotRender: XCTestCase {
    func render<V: View>(_ name: String, _ view: V, size: CGSize = CGSize(width: 900, height: 700)) throws {
        guard let dir = ProcessInfo.processInfo.environment["CP_SNAPSHOT_DIR"] else { throw XCTSkip("no dir") }
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: CPColor.palette.isLight ? .aqua : .darkAqua)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return XCTFail("no rep") }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("png") }
        try png.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
    }

    func testRenderScreens() throws {
        try render("settings-general", AppSettingsView(tab: .general))
        try render("settings-java", AppSettingsView(tab: .java))
        for t in CPThemeID.allCases {
            CPColor.palette = t.palette
            try render("theme-\(t.rawValue)", AppSettingsView(tab: .general), size: CGSize(width: 700, height: 420))
        }
        CPColor.palette = .dark
    }

    func testRenderQuickStartRam() throws {
        let container = try ModelContainer(for: ServerRecord.self, MetricSample.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        try render("quickstart", QuickStartSheet(onCreated: { _ in }).environment(ProcessManager()).modelContainer(container),
                   size: CGSize(width: 520, height: 760))
        var ram = 16384.0, players = 2
        try render("rampicker-over", RamPicker(ramMB: Binding(get: { ram }, set: { ram = $0 }), kind: .minigame,
                                               players: Binding(get: { players }, set: { players = $0 }), followsInitially: false)
                    .padding(20).background(CPColor.surface), size: CGSize(width: 520, height: 300))
    }

    func testRenderChatAndMap() throws {
        let container = try ModelContainer(for: ServerRecord.self, MetricSample.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let dir = FileManager.default.temporaryDirectory.appending(path: "cp-chat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rec = ServerRecord(name: "MCServ", path: dir.path, serverType: .fabric, launchTarget: "server.jar",
                               mcVersion: "26.2", javaPath: "java", ramMB: 4096)
        container.mainContext.insert(rec)
        let rt = ServerRuntime(serverID: rec.id)
        for l in ["Steve joined the game", "Alex joined the game", "<Steve> anyone found diamonds yet?",
                  "<Alex> 3 so far, meet me at spawn", "Steve has made the advancement [Diamonds!]", "[Server] backup in 5 minutes",
                  ".BedrockBob joined the game", "<.BedrockBob> hi from my phone"] {
            rt.push(.stdout, "[12:00:00] [Server thread/INFO]: \(l)")
        }
        rt.appendChat(.mine, who: "Host", text: "welcome Bob!")
        try render("chat", ChatView(server: rec, runtime: rt).modelContainer(container), size: CGSize(width: 820, height: 600))
        try render("map-install", MapView(server: rec, runtime: rt).modelContainer(container), size: CGSize(width: 820, height: 620))
    }

    func testRenderMainWindow() throws {
        let container = try ModelContainer(for: ServerRecord.self, MetricSample.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let dir = FileManager.default.temporaryDirectory.appending(path: "cp-shot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "server-port=25565\nmotd=Hello\nonline-mode=true\n".write(to: dir.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        let a = ServerRecord(name: "Survival SMP", path: dir.path, serverType: .paper, launchTarget: "server.jar",
                             mcVersion: "1.21.1", javaPath: "java", ramMB: 4096)
        let b = ServerRecord(name: "Modded", path: dir.path, serverType: .fabric, launchTarget: "fabric-server-launch.jar",
                             mcVersion: "1.20.4", javaPath: "java", ramMB: 6144)
        container.mainContext.insert(a); container.mainContext.insert(b)
        let pm = ProcessManager()
        pm.runtime(for: a.id).push(.system, "[00:00:01] [Server thread/INFO]: Starting minecraft server version 1.21.1")
        pm.runtime(for: a.id).push(.stdout, "[00:00:05] [Server thread/INFO]: Done (3.2s)! For help, type \"help\"")
        try render("main-overview", ServerListView().environment(pm).modelContainer(container), size: CGSize(width: 1200, height: 800))
        try render("wizard", CreateServerWizard(onCreated: { _ in }).environment(pm).modelContainer(container), size: CGSize(width: 620, height: 640))
        try render("welcome", OverviewView(servers: [], onCreated: { _ in }) { _ in }.environment(pm), size: CGSize(width: 1000, height: 700))
        CPColor.palette = .light
        try render("light-overview", ServerListView().environment(pm).modelContainer(container), size: CGSize(width: 1200, height: 800))
        for section in [ServerSection.players, .network] {
            var pending: ServerSection? = section
            try render("light-\(section.rawValue)",
                       ServerDetailShell(server: a, pendingSection: Binding(get: { pending }, set: { pending = $0 }), onServerRemoved: {})
                        .environment(pm).modelContainer(container), size: CGSize(width: 940, height: 800))
        }
        CPColor.palette = .dark
        for section in [ServerSection.performance, .console, .network, .settings, .backups] {
            var pending: ServerSection? = section
            try render("detail-\(section.rawValue)",
                       ServerDetailShell(server: a, pendingSection: Binding(get: { pending }, set: { pending = $0 }), onServerRemoved: {})
                        .environment(pm).modelContainer(container), size: CGSize(width: 940, height: 800))
        }
    }

    func testRenderBandProbe() throws {
        let container = try ModelContainer(for: ServerRecord.self, MetricSample.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let dir = FileManager.default.temporaryDirectory.appending(path: "cp-shot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let a = ServerRecord(name: "Survival SMP", path: dir.path, serverType: .paper, launchTarget: "server.jar",
                             mcVersion: "1.21.1", javaPath: "java", ramMB: 4096)
        container.mainContext.insert(a)
        let pm = ProcessManager()
        UserDefaults.standard.set(true, forKey: "cp.sidebarCollapsed")
        defer { UserDefaults.standard.removeObject(forKey: "cp.sidebarCollapsed") }
        try render("band-probe-list", ServerListView().environment(pm).modelContainer(container), size: CGSize(width: 1200, height: 800))
        var pending: ServerSection? = .mods
        try render("band-probe", HStack(spacing: 0) {
            Color.blue.frame(width: 76)
            Divider().overlay(CPColor.line)
            ServerDetailShell(server: a, pendingSection: Binding(get: { pending }, set: { pending = $0 }), onServerRemoved: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }.environment(pm).modelContainer(container), size: CGSize(width: 1200, height: 800))
    }

    func testRenderCollapsedSelected() throws {
        guard let dir = ProcessInfo.processInfo.environment["CP_SNAPSHOT_DIR"] else { throw XCTSkip("no dir") }
        let container = try ModelContainer(for: ServerRecord.self, MetricSample.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let tmp = FileManager.default.temporaryDirectory.appending(path: "cp-shot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let a = ServerRecord(name: "Survival SMP", path: tmp.path, serverType: .paper, launchTarget: "server.jar",
                             mcVersion: "1.21.1", javaPath: "java", ramMB: 4096)
        container.mainContext.insert(a)
        UserDefaults.standard.set(true, forKey: "cp.sidebarCollapsed")
        defer { UserDefaults.standard.removeObject(forKey: "cp.sidebarCollapsed") }
        let size = CGSize(width: 1500, height: 900)
        let host = NSHostingView(rootView: ServerListView().environment(ProcessManager()).modelContainer(container).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        AppRouter.shared.destination = .server(a.id, .console)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appending(path: "collapsed-selected.png"))
    }

    func testRenderPerformanceChart() throws {
        let chart = VStack(alignment: .leading, spacing: 8) {
            let now = Int64(Date().timeIntervalSince1970)
            AreaHistoryChart(points: (0..<90).map { i in .init(ts: now - 300 + Int64(i) * 2, value: 1800 + 700 * sin(Double(i) / 9) + Double(i) * 8) },
                             color: CPColor.accent, yMax: 4096, formatValue: { String(format: "%.1f GB", $0 / 1024) },
                             detailed: true, window: (now - 300)...now)
        }.padding(20).background(CPColor.surface2)
        try render("perf-chart", chart, size: CGSize(width: 800, height: 260))
    }
}
