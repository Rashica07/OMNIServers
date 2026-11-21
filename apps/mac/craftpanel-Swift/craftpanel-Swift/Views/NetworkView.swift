import SwiftUI
import AppKit

/// "How do my friends join?" — the recommended join address (live tunnel
/// > saved manual address > LAN), a QR code, a reach ladder, and the
/// in-app `bore` tunnel. Direct UI port of `NetworkPanel.tsx`'s core
/// flow, backed by `NetworkInfo`/`TunnelManager`/`QRCode`.
///
/// Automatic router port-forwarding (UPnP) and the Geyser UDP forward are
/// ported via the native `UPnP` client.
struct NetworkView: View {
    let server: ServerRecord
    @Environment(ProcessManager.self) private var processes

    @State private var info: NetInfo?
    @State private var loading = true
    @State private var manualAddress = ""
    @State private var tunnelBusy = false
    @State private var tunnelErrorShown: String?
    @State private var xp: CrossplayStatus?
    @State private var xpBusy = false
    @State private var xpErrorText: String?
    @State private var bedrockPublicIP: String?
    @State private var upnp: (available: Bool, mapped: Bool)?
    @State private var upnpBusy = false
    @State private var upnpAddress: String?
    @State private var upnpError: String?
    @State private var inviteCopied = false
    @State private var lanTestBusy = false
    @State private var lanTestResult: String?

    private var root: URL { URL(fileURLWithPath: server.path) }
    private var tunnelStatus: TunnelStatus { TunnelManager.shared.status(server.id) }

    /// Saved manual address > live tunnel > LAN (same as the header chip). Matches `net_info`'s own
    /// precedence exactly, minus the UPnP-mapped-public-address rung this
    /// build doesn't compute (see the type's doc comment).
    private var recommended: String? {
        let saved = server.manualTunnelAddress?.trimmingCharacters(in: .whitespaces) ?? ""
        if !saved.isEmpty { return saved }
        if let live = tunnelStatus.address { return live }
        if upnp?.mapped == true, let pub = info?.publicAddress { return pub }
        return info?.lanAddress
    }

    private var viaTunnel: Bool { tunnelStatus.address != nil && !hasManual }
    private var hasManual: Bool { !(server.manualTunnelAddress?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) }
    private var viaManual: Bool {
        hasManual
    }
    private var lanOnly: Bool { !viaTunnel && !viaManual }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if loading {
                    ProgressView("Working out how friends can reach you…")
                        .frame(maxWidth: .infinity)
                        .padding(40)
                } else {
                    joinCard
                    outsideWifiCard
                    PlayitCard(server: server)
                    ShareCard(server: server)
                    PortRulesCard(server: server)
                    reachLadderCard
                    upnpCard
                    tunnelCard
                    manualAddressCard
                    if let xp, xp.compatible {
                        crossplayCard(xp)
                    }
                }
            }
            .padding(16)
        }
        .background(CPColor.bg)
        .navigationTitle("Network")
        .task(id: server.id) {
            manualAddress = server.manualTunnelAddress ?? ""
            await reload()
        }
    }

    // MARK: - Bedrock cross-play

    private func crossplayCard(_ status: CrossplayStatus) -> some View {
        SettingsCard(title: "Bedrock cross-play", symbol: "gamecontroller",
                     description: "Let friends on phone, console or the Windows store edition join this Java server — no Java account needed.") {
            if let xpErrorText {
                Label(xpErrorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(CPColor.warn)
            }
            if !status.geyser {
                Button(xpBusy ? "Installing…" : "Turn on cross-play") {
                    Task { await enableCrossplay() }
                }
                .cpButton(.primary)
                .disabled(xpBusy)
            } else {
                HStack(spacing: 6) {
                    Label("Geyser", systemImage: "checkmark").font(.caption2).foregroundStyle(CPColor.ok)
                    Label(status.floodgate ? "Floodgate" : "Floodgate missing", systemImage: status.floodgate ? "checkmark" : "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(status.floodgate ? CPColor.ok : CPColor.warn)
                }
                if status.needsUpdate {
                    Label("This Geyser is too old for Bedrock 26.60 (needs build \(BedrockNetwork.minGeyserBuild) or newer). Update it so players on the new Bedrock version can join.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(CPColor.warn)
                    Button(xpBusy ? "Updating…" : "Update Geyser") { Task { await updateGeyser() } }
                        .cpButton(.primary, size: .sm).disabled(xpBusy)
                }
                if status.cloneRemotePort {
                    Label("Geyser's config has clone-remote-port on, which can't use the built-in Bedrock sign-in. Turn it off in Geyser's config.yml.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(CPColor.warn)
                }
                let bedrockAddr = BedrockNetwork.bedrockAddress(publicIP: bedrockPublicIP, lanIP: info?.lanAddress, port: Int(status.bedrockPort))
                if !bedrockAddr.isEmpty {
                    Text("\(bedrockPublicIP == nil ? "Bedrock address on your Wi-Fi" : "Bedrock address"): \(bedrockAddr)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                Text("Bedrock 26.60 signs in over TCP and plays over UDP on port \(status.bedrockPort), so both must be open. \(BedrockNetwork.tunnelNote) \(BedrockNetwork.trustPromptNote)")
                    .font(.caption).foregroundStyle(CPColor.inkFaint)
                Button("Forward TCP + UDP \(status.bedrockPort) automatically") {
                    Task {
                        do {
                            let rules = BedrockNetwork.geyserRules(bedrockPort: Int(status.bedrockPort))
                            let addr = try await UPnP.forward(rules: rules, description: "OMNIServers Bedrock (Geyser)")
                            bedrockPublicIP = addr.split(separator: ":").first.map(String.init)
                            xpErrorText = nil
                        }
                        catch { xpErrorText = error.localizedDescription }
                    }
                }
                .cpButton(.secondary, size: .sm)
                Button("Remove Cross-play", role: .destructive) {
                    CrossplayManager.disable(serverDir: root, serverType: server.serverType)
                    xp = CrossplayManager.status(serverDir: root, serverType: server.serverType)
                }
                .disabled(xpBusy)
            }
        }
    }

    private func updateGeyser() async {
        xpBusy = true; xpErrorText = nil
        defer { xpBusy = false }
        do {
            xp = try await CrossplayManager.updateGeyser(serverDir: root, serverType: server.serverType)
        } catch {
            xpErrorText = error.localizedDescription
            xp = CrossplayManager.status(serverDir: root, serverType: server.serverType)
        }
    }

    private func enableCrossplay() async {
        xpBusy = true; xpErrorText = nil
        defer { xpBusy = false }
        do {
            xp = try await CrossplayManager.enable(serverDir: root, serverType: server.serverType, mcVersion: server.mcVersion)
        } catch {
            xpErrorText = error.localizedDescription
            xp = CrossplayManager.status(serverDir: root, serverType: server.serverType)
        }
    }

    // MARK: - Join address + QR

    private var joinCard: some View {
        SettingsCard(title: "Tell your friends to join", symbol: "person.2.wave.2") {
            if let recommended {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(recommended)
                                .font(.system(.title3, design: .monospaced).weight(.semibold))
                                .foregroundStyle(CPColor.accentSoft)
                                .textSelection(.enabled)
                            IconButton(systemName: "doc.on.doc", size: 26, help: "Copy") {
                                copy(recommended)
                            }
                        }
                        reachBanner
                        HStack(spacing: 8) {
                            Button(inviteCopied ? "Invite copied" : "Copy invite") {
                                copyInvite()
                            }
                            .cpButton(.secondary, size: .sm)
                            Button(lanTestBusy ? "Checking…" : "Test this network") {
                                Task { await testLAN() }
                            }
                            .cpButton(.secondary, size: .sm)
                            .disabled(lanTestBusy)
                        }
                        if let lanTestResult {
                            Text(lanTestResult)
                                .font(.caption2)
                                .foregroundStyle(CPColor.inkFaint)
                        }
                        if lanOnly, !tunnelStatus.running {
                            Button(tunnelBusy ? "Starting…" : "Make it work from anywhere") {
                                Task { await startTunnel() }
                            }
                            .cpButton(.primary)
                            .disabled(tunnelBusy)
                        }
                    }
                    Spacer(minLength: 0)
                    if let img = QRCode.image(for: recommended) {
                        VStack(spacing: 4) {
                            Image(nsImage: img)
                                .interpolation(.none)
                                .resizable()
                                .frame(width: 108, height: 108)
                                .padding(8)
                                .background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            Label("Scan on a phone", systemImage: "iphone")
                                .font(.caption2)
                                .foregroundStyle(CPColor.inkFaint)
                        }
                    }
                }
            } else {
                Text("OMNIServers works out the join address from the running server's port. Start it once and this page fills in.")
                    .font(.callout)
                    .foregroundStyle(CPColor.inkFaint)
            }
        }
    }

    private var reachBanner: some View {
        let (icon, title, blurb, ok): (String, String, String, Bool) =
            viaTunnel
                ? ("globe", "Anyone, anywhere.", "Reachable through the tunnel.", true)
                : viaManual
                    ? ("globe", "Anyone, anywhere.", "Reachable at the address you set.", true)
                    : ("wifi", "Only people on your Wi-Fi.", "Friends somewhere else won't reach this yet — turn on the free tunnel below.", false)
        return Label {
            (Text(title).fontWeight(.semibold) + Text(" \(blurb)"))
        } icon: {
            Image(systemName: icon)
        }
        .font(.caption)
        .foregroundStyle(ok ? CPColor.okSoft : CPColor.warnSoft)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background((ok ? CPColor.ok : CPColor.warn).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // MARK: - Reach ladder

    /// Plain-language answer to "how do friends outside my Wi-Fi join?".
    private var outsideWifiCard: some View {
        SettingsCard(title: "Friends outside your Wi-Fi?", symbol: "globe",
                     description: isUDP
                        ? "Bedrock can't use the free tunnel. Forward TCP and UDP port \(info?.port ?? NetworkInfo.port(serverDir: root)) on your router to this Mac, then share your public IP."
                        : "Two steps: start the free tunnel below, then send friends the address it shows. No router settings needed.") {
            if !isUDP {
                HStack(spacing: 8) {
                    Label(tunnelStatus.running ? (tunnelStatus.address ?? "Opening the tunnel…") : "Tunnel is off",
                          systemImage: tunnelStatus.running ? "checkmark.circle.fill" : "circle.dashed")
                        .font(.callout).foregroundStyle(tunnelStatus.running ? CPColor.ok : CPColor.inkFaint)
                    Spacer()
                    if !tunnelStatus.running {
                        Button(tunnelBusy ? "Starting…" : "Start tunnel") { Task { await startTunnel() } }
                            .cpButton(.primary, size: .sm).disabled(tunnelBusy)
                    } else if let a = tunnelStatus.address {
                        Button("Copy address") { copy(a) }.cpButton(.secondary, size: .sm)
                    }
                }
            }
            Button("Step-by-step help") {
                AppRouter.shared.helpContext = "public"; AppRouter.shared.showHelp = true
            }
            .cpButton(.secondary, size: .sm)
        }
    }

    private var reachLadderCard: some View {
        SettingsCard(title: "Who can reach this server", symbol: "square.stack.3d.up") {
            ReachRow(
                symbol: "wifi", label: "People on your Wi-Fi",
                detail: info?.lanAddress.map { "Anyone in the house can use \($0)" } ?? "Start the server to find your local address.",
                state: info?.lanAddress != nil ? .ok : .off
            )
            Rectangle().fill(CPColor.lineSoft).frame(height: 1)
            ReachRow(
                symbol: "globe", label: "People on the internet",
                detail: viaTunnel ? "Reachable through the tunnel."
                    : viaManual ? "Reachable at the address you set."
                    : (info?.likelyCGNAT ?? false) ? "Your internet provider blocks port-forwarding (carrier NAT). Use the tunnel."
                    : "Not reachable yet — start the tunnel below, or forward the port on your router.",
                state: (viaTunnel || viaManual) ? .ok : .warn
            )
            if lanOnly {
                Rectangle().fill(CPColor.lineSoft).frame(height: 1)
                VStack(alignment: .leading, spacing: 6) {
                    Text("School or guest Wi-Fi?").font(.callout.weight(.medium))
                    Text("Those networks can stop devices from seeing each other, even when the server is running. Copy this exact request for IT, or use the tunnel above.")
                        .font(.caption2).foregroundStyle(CPColor.inkFaint)
                    Button("Copy request for IT") {
                        copy(NetworkInvite.schoolNetworkRequest(port: info?.port ?? NetworkInfo.port(serverDir: root), udp: isUDP, bothProtocols: isUDP))
                    }
                    .cpButton(.secondary, size: .sm)
                }
            }
        }
    }

    // MARK: - UPnP

    private var isUDP: Bool { server.serverType.isBedrock }

    /// Java: TCP. Bedrock 26.60: TCP sign-in plus UDP game on the same port.
    private func upnpRules(_ port: UInt16) -> [PortRule] {
        [PortRule(proto: isUDP ? .both : .tcp, port: Int(port), label: "Game")]
    }

    private var upnpCard: some View {
        SettingsCard(title: "Automatic port-forward", symbol: "arrow.left.arrow.right",
                     description: "Asks your router (UPnP) to forward this server's \(isUDP ? "TCP and UDP" : "TCP") port to this Mac for 24 hours. Works on most home routers; not on carrier-NAT connections.") {
            VStack(alignment: .leading, spacing: 8) {
                if upnp == nil {
                    Label("Looking for your router…", systemImage: "hourglass").font(.system(size: 12)).foregroundStyle(CPColor.inkFaint)
                } else if upnp?.available == false {
                    Text("No UPnP router found on this network — use the tunnel instead.").font(.system(size: 12)).foregroundStyle(CPColor.inkFaint)
                } else {
                    HStack {
                        if upnp?.mapped == true {
                            Badge(text: "Forwarded", tone: .ok, symbol: "checkmark")
                            if let a = upnpAddress ?? info?.publicAddress {
                                Text(a).font(CPFont.mono(12)).textSelection(.enabled)
                            }
                            Spacer()
                            Button("Remove") { Task { await upnpRemove() } }.cpButton(.ghost, size: .sm).disabled(upnpBusy)
                        } else {
                            Button(upnpBusy ? "Forwarding…" : "Forward port \(info?.port ?? NetworkInfo.port(serverDir: root))") {
                                Task { await upnpForward() }
                            }
                            .cpButton(.primary, size: .sm).disabled(upnpBusy || (info?.likelyCGNAT ?? false))
                        }
                    }
                }
                if let upnpError { Text(upnpError).font(.system(size: 11)).foregroundStyle(CPColor.bad) }
            }
        }
        .task(id: server.id) {
            let port = NetworkInfo.port(serverDir: root)
            upnp = await UPnP.status(rules: upnpRules(port))
        }
    }

    private func upnpForward() async {
        upnpBusy = true; upnpError = nil
        defer { upnpBusy = false }
        do {
            upnpAddress = try await UPnP.forward(rules: upnpRules(info?.port ?? NetworkInfo.port(serverDir: root)))
            upnp = (true, true)
        } catch { upnpError = error.localizedDescription }
    }

    private func upnpRemove() async {
        upnpBusy = true; upnpError = nil
        defer { upnpBusy = false }
        do {
            try await UPnP.remove(rules: upnpRules(info?.port ?? NetworkInfo.port(serverDir: root)))
            upnp = (true, false); upnpAddress = nil
        } catch { upnpError = error.localizedDescription }
    }

    // MARK: - Tunnel

    private var tunnelCard: some View {
        SettingsCard(title: "Free tunnel", symbol: "network",
                     description: "One click gives you a bore.pub address reachable from anywhere. Stable while running; changes on restart.") {
            if tunnelStatus.running {
                if let addr = tunnelStatus.address {
                    Label(addr, systemImage: "checkmark.circle.fill")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(CPColor.ok)
                } else {
                    Label("Opening the tunnel…", systemImage: "hourglass")
                        .font(.callout).foregroundStyle(CPColor.inkFaint)
                }
                Button("Stop Tunnel", role: .destructive) {
                    TunnelManager.shared.stop(serverID: server.id)
                }
            } else {
                Button(tunnelBusy ? "Starting…" : "Start Tunnel") {
                    Task { await startTunnel() }
                }
                .cpButton(.primary)
                .disabled(tunnelBusy)
            }
            if let err = tunnelStatus.error {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(CPColor.warn)
            }
        }
    }

    // MARK: - Manual address

    private var manualAddressCard: some View {
        SettingsCard(title: "Or paste your own address", symbol: "link",
                     description: "Already have a playit.gg / ngrok / static address? Paste it here — it wins over the LAN address whenever no tunnel is running.") {
            HStack {
                TextField("play.example.com:25565", text: $manualAddress)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    server.manualTunnelAddress = manualAddress.trimmingCharacters(in: .whitespaces)
                }
                .disabled(manualAddress.trimmingCharacters(in: .whitespaces) == (server.manualTunnelAddress ?? ""))
                if !(server.manualTunnelAddress ?? "").isEmpty {
                    Button("Clear", role: .destructive) {
                        manualAddress = ""
                        server.manualTunnelAddress = nil
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func reload() async {
        loading = true
        defer { loading = false }
        info = await NetworkInfo.info(serverDir: root)
        xp = CrossplayManager.status(serverDir: root, serverType: server.serverType)
    }

    private func startTunnel() async {
        tunnelBusy = true
        defer { tunnelBusy = false }
        let port = info?.port ?? NetworkInfo.port(serverDir: root)
        await TunnelManager.shared.start(serverID: server.id, port: port)
    }

    private func copy(_ text: String) {
        Toasts.shared.copy(text, what: "Text")
    }

    private func copyInvite() {
        guard let recommended else { return }
        let worksAnywhere = viaTunnel || viaManual || upnp?.mapped == true
        copy(NetworkInvite.text(serverName: server.name, address: recommended, serverType: server.serverType,
                                mcVersion: server.mcVersion, worksAnywhere: worksAnywhere))
        inviteCopied = true
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            inviteCopied = false
        }
    }

    private func testLAN() async {
        let port = info?.port ?? NetworkInfo.port(serverDir: root)
        lanTestBusy = true
        defer { lanTestBusy = false }
        let local = await NetworkInfo.canConnect(host: "127.0.0.1", port: port)
        guard local else {
            lanTestResult = "Nothing is answering on port \(port). Start the server and wait until it says Running."
            return
        }
        guard let host = info?.lanIP else {
            lanTestResult = "The server answers on this Mac. OMNIServers could not find this Mac's LAN address, so check the network connection or use the tunnel."
            return
        }
        let lan = await NetworkInfo.canConnect(host: host, port: port)
        lanTestResult = lan
            ? "The server answers on \(host):\(port). People on this network can use that address; if they still cannot join, the network may isolate devices — try the tunnel or send the IT request below."
            : "The server runs, but is not answering on \(host):\(port). macOS Firewall or this network may be blocking it; try the tunnel or ask IT to allow the port."
    }
}

private struct ReachRow: View {
    enum State { case ok, warn, off }
    let symbol: String
    let label: String
    let detail: String
    let state: State

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.15))
                Image(systemName: symbol).font(.caption).foregroundStyle(tint)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(label).font(.callout.weight(.medium))
                    Circle().fill(tint).frame(width: 6, height: 6)
                }
                Text(detail).font(.caption2).foregroundStyle(CPColor.inkFaint)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private var tint: Color {
        switch state {
        case .ok: CPColor.ok
        case .warn: CPColor.warn
        case .off: CPColor.inkGhost
        }
    }
}
