import SwiftUI
import SwiftData
import WebKit

/// Live map tab: installs BlueMap on first use (with the Mojang texture
/// consent BlueMap requires), then shows its web map — every dimension,
/// live player markers — right here. Friends on your network can open
/// the same map in a browser.
struct MapView: View {
    let server: ServerRecord
    let runtime: ServerRuntime
    @Query private var allServers: [ServerRecord]

    @State private var installed = false
    @State private var consent = false
    @State private var port = BlueMap.defaultPort
    @State private var up = false
    @State private var busy: String?
    @State private var error: String?
    @State private var needsRestart = false
    @State private var agreed = false
    @State private var reloadToken = 0

    private var dir: URL { URL(fileURLWithPath: server.path) }

    var body: some View {
        Group {
            if !BlueMap.supported(server.serverType) {
                ScrollView { unsupported.padding(24) }
            } else if !installed {
                ScrollView { installCard.padding(24) }
            } else if !consent {
                ScrollView { consentCard.padding(24) }
            } else if !runtime.isRunning {
                CPEmptyState(icon: "map", title: "Start the server to see the map",
                             message: "BlueMap runs inside your server — the map comes alive as soon as it's up.")
            } else if needsRestart {
                ScrollView { restartCard.padding(24) }
            } else if up {
                mapPane
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting the map…").font(.system(size: 13, weight: .semibold)).foregroundStyle(CPColor.ink)
                    Text("The first render of a big world can take a few minutes; the map fills in as it goes.")
                        .font(.system(size: 12)).foregroundStyle(CPColor.inkFaint).multilineTextAlignment(.center)
                }
                .frame(maxWidth: 360).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CPColor.bg)
        .task(id: runtime.isRunning) { await poll() }
    }

    // MARK: - States

    private var unsupported: some View {
        SettingsCard(title: "Live map", symbol: "map") {
            Text(server.serverType.isBedrock
                 ? "Bedrock servers can't run BlueMap."
                 : "Vanilla servers can't load add-ons. Switch this server to Paper or Fabric with **Change Version** in the ⋯ menu — your world stays — and the live map becomes available.")
                .font(.system(size: 13)).foregroundStyle(CPColor.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var installCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(systemName: "map.fill").font(.system(size: 28)).foregroundStyle(CPColor.accent)
                    .frame(width: 56, height: 56)
                    .background(CPColor.accentMuted, in: RoundedRectangle(cornerRadius: CPRadius.lg))
                VStack(alignment: .leading, spacing: 3) {
                    Text("A live map of your world").font(CPFont.display(20)).foregroundStyle(CPColor.ink)
                    Text("Powered by BlueMap — free and open source.").font(.system(size: 12)).foregroundStyle(CPColor.inkFaint)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                feature("cube", "3D and flat views you can fly around")
                feature("globe.europe.africa", "Overworld, Nether and End — switch in the map")
                feature("person.2", "See where everyone is, live")
                feature("wifi", "Friends on your network can open it in a browser")
            }
            consentText
            if let error { CPBanner(tone: .bad, message: error) }
            HStack {
                if let busy { ProgressView().controlSize(.small); Text(busy).font(.system(size: 12)).foregroundStyle(CPColor.inkDim) }
                Spacer()
                Button("Install BlueMap") { Task { await install() } }
                    .cpButton(.primary)
                    .disabled(!agreed || busy != nil)
            }
        }
        .padding(20)
        .frame(maxWidth: 560, alignment: .leading)
        .background(CPColor.surface2, in: RoundedRectangle(cornerRadius: CPRadius.xl))
        .overlay(RoundedRectangle(cornerRadius: CPRadius.xl).strokeBorder(CPColor.lineSoft))
        .frame(maxWidth: .infinity)
    }

    private var consentText: some View {
        Toggle(isOn: $agreed) {
            Text("BlueMap downloads Minecraft's textures from Mojang once, to draw the map. I own Minecraft: Java Edition and accept [Mojang's EULA](https://www.minecraft.net/eula).")
                .font(.system(size: 12)).foregroundStyle(CPColor.inkDim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
    }

    private var consentCard: some View {
        SettingsCard(title: "One more step", symbol: "map") {
            VStack(alignment: .leading, spacing: 12) {
                Text("BlueMap is installed but hasn't been allowed to download the textures it needs.")
                    .font(.system(size: 13)).foregroundStyle(CPColor.inkDim)
                consentText
                if let error { CPBanner(tone: .bad, message: error) }
                Button("Allow and turn on the map") { Task { await giveConsent() } }
                    .cpButton(.primary).disabled(!agreed)
            }
        }
        .frame(maxWidth: 560).frame(maxWidth: .infinity)
    }

    private var restartCard: some View {
        SettingsCard(title: "Restart to turn on the map", symbol: "arrow.clockwise") {
            VStack(alignment: .leading, spacing: 12) {
                Text("BlueMap is installed. The server needs a restart to load it — players online will be disconnected briefly.")
                    .font(.system(size: 13)).foregroundStyle(CPColor.inkDim)
                HStack {
                    if let busy { ProgressView().controlSize(.small); Text(busy).font(.system(size: 12)) }
                    Spacer()
                    Button("Restart now") { Task { await restart() } }.cpButton(.primary).disabled(busy != nil)
                }
            }
        }
        .frame(maxWidth: 560).frame(maxWidth: .infinity)
    }

    private var mapPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(CPColor.ok).frame(width: 7, height: 7)
                Text("Live").font(.system(size: 12, weight: .semibold))
                if let lan = NetworkInfo.lanIP() {
                    let link = "http://\(lan):\(port)"
                    Text("Friends on your network: \(link)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(CPColor.inkFaint)
                        .textSelection(.enabled)
                    Button { Toasts.shared.copy(link, what: "Map link") } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .cpButton(.quiet, size: .sm).help("Copy link")
                }
                Spacer()
                Button { reloadToken += 1 } label: { Label("Reload", systemImage: "arrow.clockwise") }.cpButton(.ghost, size: .sm)
                Button { NSWorkspace.shared.open(BlueMap.localURL(port: port)) } label: { Label("Open in browser", systemImage: "safari") }
                    .cpButton(.ghost, size: .sm)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
            WebMap(url: BlueMap.localURL(port: port), reloadToken: reloadToken)
        }
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        Label { Text(text).font(.system(size: 13)).foregroundStyle(CPColor.ink) } icon: {
            Image(systemName: symbol).foregroundStyle(CPColor.accent).frame(width: 20)
        }
    }

    // MARK: - Actions

    private func refreshState() {
        installed = BlueMap.isInstalled(dir, type: server.serverType)
        consent = BlueMap.consentGiven(dir, type: server.serverType)
        port = BlueMap.port(dir, type: server.serverType)
    }

    /// Re-checks files and whether the map answers, every 2 s while shown.
    private func poll() async {
        while !Task.isCancelled {
            refreshState()
            up = installed && consent && runtime.isRunning ? await BlueMap.isUp(port: port) : false
            if up { needsRestart = false }
            try? await Task.sleep(for: .seconds(up ? 10 : 2))
        }
    }

    private func install() async {
        busy = "Installing BlueMap…"; error = nil
        defer { busy = nil }
        let others = allServers.filter { $0.id != server.id }.map { (dir: URL(fileURLWithPath: $0.path), type: $0.serverType) }
        do {
            try await BlueMap.install(dir, type: server.serverType, mcVersion: server.mcVersion,
                                      port: BlueMap.pickPort(otherServers: others))
            refreshState()
            needsRestart = runtime.isRunning
        } catch {
            self.error = "Couldn't install BlueMap: \(error.localizedDescription)"
        }
    }

    private func giveConsent() async {
        let others = allServers.filter { $0.id != server.id }.map { (dir: URL(fileURLWithPath: $0.path), type: $0.serverType) }
        do {
            try BlueMap.configure(dir, type: server.serverType, port: BlueMap.pickPort(otherServers: others))
            refreshState()
            if runtime.isRunning {
                if (try? runtime.writeStdin("bluemap reload")) == nil {
                    _ = try? await RconService.shared.run(record: server, command: "bluemap reload")
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func restart() async {
        busy = "Restarting…"
        defer { busy = nil }
        try? runtime.stop()
        for _ in 0..<120 where runtime.isRunning { try? await Task.sleep(for: .milliseconds(500)) }
        do { try runtime.start(record: server) } catch { self.error = error.localizedDescription }
        needsRestart = false
    }
}

/// BlueMap's web app in a WKWebView.
private struct WebMap: NSViewRepresentable {
    let url: URL
    let reloadToken: Int

    final class Coordinator { var token = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        view.load(URLRequest(url: url))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.token != reloadToken {
            context.coordinator.token = reloadToken
            view.reload()
        } else if view.url?.host != url.host || view.url?.port != url.port {
            view.load(URLRequest(url: url))
        }
    }
}
