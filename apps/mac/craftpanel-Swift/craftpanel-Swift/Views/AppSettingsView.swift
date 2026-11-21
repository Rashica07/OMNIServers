import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

/// OMNIServers's own settings — native port of `SettingsPage.tsx`: header,
/// underline tabs (General · Account · Updates · Java · Backups ·
/// Diagnostics · About), a centered 672 pt column of cards. Every control
/// saves immediately (native convention; the web page had a Save button —
/// listed as an intentional deviation in DESIGN_TOKENS.md).
///
/// Shown both in the main window (sidebar → "OMNIServers settings", like
/// Tauri) and in the standard macOS Settings window (⌘,).
struct AppSettingsView: View {
    enum Tab: String, CaseIterable, Hashable {
        case general, account, updates, java, backups, diagnostics, about
        var label: String { rawValue.capitalized }
        var symbol: String {
            switch self {
            case .general: "slider.horizontal.3"
            case .account: "person.crop.circle"
            case .updates: "arrow.down.circle"
            case .java: "cpu"
            case .backups: "archivebox"
            case .diagnostics: "waveform.path.ecg"
            case .about: "info.circle"
            }
        }
    }

    @State var tab: Tab = .general
    var showsHeader = true

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                Text("OMNIServers settings")
                    .font(CPFont.display(22))
                    .foregroundStyle(CPColor.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.top, 20)
                    .padding(.bottom, 12)
                    .background(CPColor.surface)
                    .overlay(alignment: .bottom) { Rectangle().fill(CPColor.line).frame(height: 1) }
            }
            HStack(spacing: 0) {
                VStack(spacing: 2) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        SettingsRailItem(label: t.label, symbol: t.symbol, isActive: tab == t) {
                            withAnimation(.easeInOut(duration: 0.18)) { tab = t }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .frame(width: 156)
                .background(CPColor.surface)
                Divider().overlay(CPColor.line)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch tab {
                        case .general: GeneralSettings()
                        case .account: AccountSettings()
                        case .updates: UpdateSettings()
                        case .java: JavaSettings()
                        case .backups: BackupSettings()
                        case .diagnostics: DiagnosticsSettings()
                        case .about: AboutSettings()
                        }
                    }
                    .frame(maxWidth: 672)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(CPColor.bg)
    }
}

/// One row of the settings side rail (same look as the server page's rail).
private struct SettingsRailItem: View {
    let label: String
    let symbol: String
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 16)
                Text(label).font(.system(size: 12.5, weight: isActive ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isActive ? CPColor.ink : CPColor.inkFaint)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(isActive ? CPColor.surface3 : (hovering ? CPColor.surface2 : .clear),
                        in: RoundedRectangle(cornerRadius: CPRadius.sm, style: .continuous))
            .overlay(alignment: .leading) {
                Capsule().fill(isActive ? CPColor.accent : .clear).frame(width: 3, height: 16).offset(x: -5)
            }
            .contentShape(Rectangle())
        }
        .cpTap(hoverScale: 1.0, shake: false)
        .onHover { hovering = $0 }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @State private var theme = ThemeStore.shared.theme
    @State private var ram = Double(AppDefaults.defaultRAMMB)
    @State private var java = AppDefaults.defaultJavaPath
    @State private var keepOnQuit = AppDefaults.keepServersOnQuit
    @State private var autoTunnel = AppDefaults.autoTunnel
    @State private var stayAwake = AppDefaults.stayAwakeOnPower
    @State private var lidClosed = false
    @State private var lidBusy = false
    @State private var expert = AppDefaults.expertMode
    @State private var lightMode = AppDefaults.lightMode

    var body: some View {
        SettingsCard(title: "Theme", symbol: "paintpalette", description: "Applies immediately — no restart, no Save button.") {
            HStack(spacing: 10) {
                ForEach(CPThemeID.allCases) { t in
                    ThemeSwatch(theme: t, selected: theme == t) {
                        theme = t
                        ThemeStore.shared.set(t)
                    }
                }
            }
        }

        SettingsCard(title: "Defaults for new servers", symbol: "slider.horizontal.3") {
            CPField(label: "Default Java", hint: "used for new servers — `java` = whatever's on PATH") {
                TextField("java", text: $java)
                    .textFieldStyle(.roundedBorder)
                    .font(CPFont.mono())
                    .onChange(of: java) { _, v in AppDefaults.defaultJavaPath = v.isEmpty ? "java" : v }
            }
            CPField(label: "Default memory for new servers") {
                HStack {
                    CPSlider(value: $ram, range: 1024...Double(max(4096, SystemRAM.totalMB)), step: 512)
                        .frame(height: 20)
                        .onChange(of: ram) { _, v in AppDefaults.defaultRAMMB = UInt32(v) }
                    Text(SystemRAM.format(mb: Int(ram)))
                        .font(.system(size: 13, design: .monospaced))
                        .frame(width: 64, alignment: .trailing)
                }
            }
            .padding(.top, 12)
            CPSettingRow(title: "Keep servers running when I quit OMNIServers",
                         hint: "Quitting won't stop your servers — the app re-adopts them next launch. (Closing the window already keeps them; this covers Quit.)") {
                CPToggle(isOn: $keepOnQuit).onChange(of: keepOnQuit) { _, v in AppDefaults.keepServersOnQuit = v }
            }
            .padding(.top, 16)
            CPSettingRow(title: "Open a free join link automatically",
                         hint: "When a Java server starts, OMNIServers opens a free tunnel and uses its address for the address chip and Invite, so friends anywhere can join. Join on your own computer still uses localhost. A permanent address you saved in the Network tab wins.") {
                CPToggle(isOn: $autoTunnel).onChange(of: autoTunnel) { _, v in AppDefaults.autoTunnel = v }
            }
            .padding(.top, 16)
            CPSettingRow(title: "Stay awake on power",
                         hint: "Stops this Mac from sleeping while it's plugged in — on battery it still sleeps normally. What lets a server's scheduled start actually fire instead of sitting there asleep.") {
                CPToggle(isOn: $stayAwake).onChange(of: stayAwake) { _, v in
                    AppDefaults.stayAwakeOnPower = v
                    PowerKeeper.shared.setEnabled(v)
                }
            }
            .padding(.top, 12)
            CPSettingRow(title: "Keep running with the lid closed",
                         hint: "Laptops sleep when you close the lid, which stops the server. This turns that off until you switch it back, and asks for your Mac password. Keep it plugged in and somewhere it can breathe.") {
                CPToggle(isOn: Binding(get: { lidClosed }, set: { v in
                    guard !lidBusy else { return }
                    lidBusy = true
                    Task {
                        _ = await LidSleep.set(disable: v)
                        lidClosed = LidSleep.isDisabled()
                        lidBusy = false
                    }
                }))
                .disabled(lidBusy)
            }
            .padding(.top, 12)
            .task { lidClosed = LidSleep.isDisabled() }
            CPSettingRow(title: "Expert mode", hint: "Shows the raw server.properties editor and other power tools.") {
                CPToggle(isOn: $expert).onChange(of: expert) { _, v in AppDefaults.expertMode = v }
            }
            .padding(.top, 12)
        }

        SettingsCard(title: "Light mode", symbol: "leaf",
                     description: "OMNIServers turns this on by default on Macs with under 8 GB of memory or fewer than 4 cores. It reduces animation and keeps a shorter console history to leave more room for the game.") {
            CPSettingRow(title: "Use Light mode", hint: "This changes OMNIServers's effects and console history; it does not change Minecraft settings.") {
                CPToggle(isOn: $lightMode).onChange(of: lightMode) { _, value in AppDefaults.lightMode = value }
            }
            let system = SystemMemory.current()
            Text("This Mac: \(SystemRAM.format(mb: system.totalMB)), \(system.cores) cores · \(lightMode ? "Light mode on" : "Light mode off")")
                .font(.caption).foregroundStyle(CPColor.inkFaint)
        }

        PlayerNoticeSettings()
    }
}

/// Join/leave notices and your in-game chat name.
private struct PlayerNoticeSettings: View {
    @AppStorage("cp.notifyJoins") private var joins = true
    @AppStorage("cp.notifyChat") private var chat = false
    @AppStorage("cp.chatName") private var chatName = "Host"

    var body: some View {
        SettingsCard(title: "Players & chat", symbol: "bell.badge") {
            CPSettingRow(title: "Tell me when players join or leave",
                         hint: "A macOS notification when OMNIServers is in the background, a small pop-up when you're in the app. Advancements too. The Dock icon shows how many are online.") {
                CPToggle(isOn: $joins)
            }
            CPSettingRow(title: "Also notify for every chat message", hint: "Can get noisy on a busy server.") {
                CPToggle(isOn: $chat)
            }
            .padding(.top, 12)
            CPField(label: "Your name in chat", hint: "Messages you send from the Chat tab show in-game as <\(chatName.isEmpty ? "Host" : chatName)> …") {
                TextField("Host", text: $chatName).textFieldStyle(.roundedBorder)
            }
            .padding(.top, 12)
        }
    }
}

private struct ThemeSwatch: View {
    let theme: CPThemeID
    let selected: Bool
    let action: () -> Void

    var body: some View {
        let (bg, surface, accent) = theme.swatch
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous).fill(bg)
                    RoundedRectangle(cornerRadius: CPRadius.sm, style: .continuous).fill(surface)
                        .frame(width: 38, height: 26).padding(6)
                    Circle().fill(accent).frame(width: 10, height: 10).padding(10)
                }
                .frame(width: 84, height: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: CPRadius.md, style: .continuous)
                        .strokeBorder(selected ? CPColor.accent : CPColor.line, lineWidth: selected ? 2 : 1)
                )
                HStack(spacing: 4) {
                    Text(theme.label).font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(selected ? CPColor.ink : CPColor.inkDim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.label) theme")
    }
}

// MARK: - Account (install id, app lock, remote access)

private struct AccountSettings: View {
    var body: some View {
        SettingsCard(title: "This install", symbol: "person.crop.circle",
                     description: "A random id for this install of OMNIServers — not you, not your servers' content. It's written into a server's hidden .craftpanel-meta.json when OMNIServers creates or adopts it. Nothing leaves your machine on its own.") {
            CopyRow(value: Attribution.installID)
        }
        LockSettingsCard()
        RemoteAccessCard()
    }
}

struct CopyRow: View {
    let value: String
    @State private var copied = false
    var body: some View {
        HStack {
            Text(value).font(CPFont.mono(12)).foregroundStyle(CPColor.inkDim).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button(copied ? "Copied" : "Copy") {
                Toasts.shared.copy(value, what: "Value")
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
            .cpButton(.secondary, size: .sm)
        }
        .padding(8)
        .background(CPColor.surface2, in: RoundedRectangle(cornerRadius: CPRadius.sm))
    }
}

private struct LockSettingsCard: View {
    @State private var isSet = AppLock.shared.isSet
    @State private var current = ""
    @State private var newPin = ""
    @State private var confirm = ""
    @State private var busy = false
    @State private var error: String?
    @State private var note: String?

    var body: some View {
        SettingsCard(title: "App lock", symbol: "lock",
                     description: "Asks for a PIN (or Touch ID) when OMNIServers opens. It keeps someone at your desk out of this app — it doesn't encrypt your servers.") {
            VStack(alignment: .leading, spacing: 10) {
                if isSet {
                    CPField(label: "Current PIN") { SecureField("", text: $current).textFieldStyle(.roundedBorder) }
                }
                CPField(label: isSet ? "New PIN" : "PIN", hint: "At least 4 characters.") {
                    SecureField("", text: $newPin).textFieldStyle(.roundedBorder)
                }
                CPField(label: "Confirm new PIN") { SecureField("", text: $confirm).textFieldStyle(.roundedBorder) }
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(CPColor.bad) }
                if let note { Text(note).font(.system(size: 11)).foregroundStyle(CPColor.ok) }
                HStack {
                    Button(isSet ? "Change PIN" : "Set PIN") { Task { await save() } }
                        .cpButton(.primary, size: .sm)
                        .disabled(busy || newPin.isEmpty || newPin != confirm || (isSet && current.isEmpty))
                    if isSet {
                        Button("Remove lock") { Task { await remove() } }
                            .cpButton(.danger, size: .sm)
                            .disabled(busy || current.isEmpty)
                    }
                    if busy { ProgressView().controlSize(.small) }
                }
            }
        }
    }

    private func save() async {
        busy = true; error = nil; note = nil
        defer { busy = false }
        let lock = AppLock.shared, cur = current, pin = newPin, wasSet = isSet
        do {
            try await Task.detached {
                if wasSet, !lock.check(pin: cur) { throw RconServiceError.message("That PIN isn't right.") }
                try lock.set(pin: pin)
            }.value
            isSet = true; current = ""; newPin = ""; confirm = ""
            note = wasSet ? "PIN updated." : "PIN set."
        } catch { self.error = error.localizedDescription }
    }

    private func remove() async {
        busy = true; error = nil; note = nil
        defer { busy = false }
        let lock = AppLock.shared, cur = current
        do {
            try await Task.detached { try lock.clear(currentPin: cur) }.value
            isSet = false; current = ""; newPin = ""; confirm = ""
            note = "Lock removed."
        } catch { self.error = error.localizedDescription }
    }
}

private struct RemoteAccessCard: View {
    @State private var api = RemoteAPIServer.shared
    @State private var pairing: String?
    @State private var error: String?

    var body: some View {
        SettingsCard(title: "Remote access", symbol: "iphone.radiowaves.left.and.right",
                     description: "A small local API the OMNIServers Discord bot and phone app use to see and control your servers. Off by default. Anyone with the token can start, stop and send commands.") {
            VStack(alignment: .leading, spacing: 0) {
                CPSettingRow(title: "Remote access", hint: api.running ? "Listening on port \(api.config.port)." : (api.lastError ?? "Off."), divider: false) {
                    CPToggle(isOn: Binding(get: { api.config.enabled }, set: { api.setEnabled($0) }))
                }
                CPSettingRow(title: "Allow other devices",
                             hint: "Needed for the phone app. Off = only apps on this Mac (like the Discord bot) can connect.") {
                    CPToggle(isOn: Binding(get: { api.config.allowRemote }, set: { api.setAllowRemote($0) }))
                }
                .padding(.top, 12)
                if api.config.enabled {
                    CPField(label: "Token only", hint: "For manual host/port/token entry, or PANEL_TOKEN for the bot.") {
                        CopyRow(value: api.config.token)
                    }
                    .padding(.top, 12)
                    HStack {
                        Button("Pair phone…") { Task { await pair() } }.cpButton(.secondary, size: .sm)
                        Button("New token") { api.regenerateToken(); pairing = nil }.cpButton(.ghost, size: .sm)
                    }
                    .padding(.top, 10)
                    if let pairing {
                        HStack(alignment: .top, spacing: 12) {
                            if let img = QRCode.image(for: pairing, scale: 5) {
                                Image(nsImage: img).interpolation(.none).resizable().frame(width: 140, height: 140)
                            }
                            CopyRow(value: pairing)
                        }
                        .padding(.top, 10)
                    }
                    if let error { Text(error).font(.system(size: 11)).foregroundStyle(CPColor.bad).padding(.top, 6) }
                }
            }
        }
    }

    private func pair() async {
        error = nil
        do { pairing = try await api.pairPayload() } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Updates

private struct UpdateSettings: View {
    @State private var checking = false
    @State private var result: UpdateCheck?
    @State private var installing = false
    @State private var status: String?
    @State private var failure: String?
    @State private var auto = AppDefaults.autoCheckUpdates

    var body: some View {
        SettingsCard(title: "Updates", symbol: "arrow.down.circle",
                     description: "OMNIServers \(Bundle.main.shortVersion). New versions come from the OMNIServers releases page on GitHub.") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button(checking ? "Checking…" : "Check for updates") { Task { await check() } }
                        .cpButton(.primary, size: .sm).disabled(checking || installing)
                    if let r = result, r.newer, r.downloadURL != nil {
                        Button(installing ? "Updating…" : "Update to \(r.latest ?? "")") { Task { await install(r) } }
                            .cpButton(.secondary, size: .sm).disabled(installing)
                    }
                }
                if let r = result {
                    if let u = r.unavailable {
                        Text(u).font(.system(size: 12)).foregroundStyle(CPColor.inkFaint)
                    } else if r.newer, let latest = r.latest {
                        Text("Version \(latest) is available.").font(.system(size: 12)).foregroundStyle(CPColor.accent)
                        if r.downloadURL == nil, let url = r.url {
                            Link("Open the release page", destination: url).font(.system(size: 12))
                        }
                    } else {
                        Text("You're on the latest version.").font(.system(size: 12)).foregroundStyle(CPColor.ok)
                    }
                }
                if let status { Text(status).font(.system(size: 12)).foregroundStyle(CPColor.inkFaint) }
                if let failure { Text(failure).font(.system(size: 12)).foregroundStyle(CPColor.bad) }
                CPSettingRow(title: "Check automatically", hint: "Looks for a new version when OMNIServers opens.") {
                    CPToggle(isOn: $auto).onChange(of: auto) { _, v in AppDefaults.autoCheckUpdates = v }
                }
            }
        }
    }

    private func check() async {
        checking = true; failure = nil; status = nil
        result = await UpdateChecker.check()
        checking = false
    }

    private func install(_ r: UpdateCheck) async {
        guard let dmg = r.downloadURL else { return }
        installing = true; failure = nil
        defer { installing = false }
        do {
            let staged = try await UpdateInstaller.prepare(dmg: dmg) { text in Task { @MainActor in status = text } }
            if UpdateInstaller.canReplaceInPlace() {
                status = "Restarting into the new version…"
                try UpdateInstaller.swapAndRelaunch(staged: staged)
                NSApp.terminate(nil)
            } else {
                status = nil
                NSWorkspace.shared.activateFileViewerSelecting([staged.appending(path: "OMNIServers.app")])
                failure = "This copy can't replace itself where it is. The new OMNIServers is selected in Finder: drag it into Applications."
            }
        } catch {
            failure = error.localizedDescription
        }
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
}

// MARK: - Java

private struct JavaSettings: View {
    @State private var runtimes: [JavaInfo] = []
    @State private var loading = true
    @State private var installing: UInt8?
    @State private var progress: String?
    @State private var error: String?

    var body: some View {
        SettingsCard(title: "Java runtimes", symbol: "cpu",
                     description: "Minecraft needs a matching Java: 1.20.5+ needs 21, 1.18–1.20.4 needs 17, 26.x needs 25. OMNIServers can install a verified Eclipse Temurin runtime for you — checksum-checked, kept in its own folder, never touching your system Java.") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach([UInt8(17), 21, 25], id: \.self) { f in
                    HStack {
                        Text("Java \(f)").font(.system(size: 13, weight: .medium))
                        Spacer()
                        if let p = JavaInstaller.installedPath(feature: f) {
                            Badge(text: "Installed", tone: .ok, symbol: "checkmark")
                            Button("Reveal") { NSWorkspace.shared.selectFile(p, inFileViewerRootedAtPath: "") }.cpButton(.ghost, size: .sm)
                        } else {
                            Button(installing == f ? "Installing…" : "Install") { Task { await install(f) } }
                                .cpButton(.secondary, size: .sm).disabled(installing != nil)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if let progress { Text(progress).font(.system(size: 11)).foregroundStyle(CPColor.inkFaint) }
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(CPColor.bad) }
            }
        }
        SettingsCard(title: "Found on this Mac", symbol: "magnifyingglass") {
            VStack(alignment: .leading, spacing: 6) {
                if loading {
                    ProgressView().controlSize(.small)
                } else if runtimes.isEmpty {
                    Text("No Java found. Install one above.").font(.system(size: 12)).foregroundStyle(CPColor.inkFaint)
                } else {
                    ForEach(runtimes, id: \.path) { r in
                        HStack {
                            Text("Java \(r.major)").font(.system(size: 12, weight: .medium)).frame(width: 60, alignment: .leading)
                            Text(r.path).font(CPFont.mono(11)).foregroundStyle(CPColor.inkDim).lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        runtimes = await JavaProbe.listRuntimes()
        loading = false
    }

    private func install(_ f: UInt8) async {
        installing = f; error = nil; progress = nil
        defer { installing = nil }
        do {
            let info = try await JavaInstaller.install(feature: f) { p in
                Task { @MainActor in progress = p.message }
            }
            progress = "Java \(info.major) installed."
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Backups

private struct BackupSettings: View {
    @State private var keep = Double(AppDefaults.backupKeep)
    var body: some View {
        SettingsCard(title: "Local backup retention", symbol: "archivebox",
                     description: "How many zip backups each server keeps before the oldest scheduled ones are pruned. Pre-restore safety backups are never pruned.") {
            CPField(label: "Keep newest", hint: "0 = unlimited") {
                HStack {
                    Stepper(value: $keep, in: 0...500, step: 1) {
                        Text(keep == 0 ? "Unlimited" : "\(Int(keep)) backups").font(.system(size: 13, design: .monospaced))
                    }
                    .onChange(of: keep) { _, v in AppDefaults.backupKeep = Int(v) }
                }
            }
        }
    }
}

// MARK: - Diagnostics

private struct DiagnosticsSettings: View {
    @Query(sort: \ServerRecord.createdAt) private var servers: [ServerRecord]
    @State private var running = false
    @State private var report: DoctorReport?
    @State private var description = ""
    @State private var selectedServerID: UUID?
    @State private var reportStatus: String?

    var body: some View {
        SettingsCard(title: "Health check", symbol: "stethoscope",
                     description: "Checks Java, free disk space and whether each server's port is free.") {
            VStack(alignment: .leading, spacing: 8) {
                Button(running ? "Checking…" : "Run health check") { Task { await run() } }
                    .cpButton(.primary, size: .sm).disabled(running)
                if let report {
                    ForEach(report.checks, id: \.id) { c in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: c.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(c.ok ? CPColor.ok : CPColor.warn)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.label).font(.system(size: 12, weight: .medium))
                                Text(c.detail).font(.system(size: 11)).foregroundStyle(CPColor.inkFaint)
                            }
                        }
                    }
                }
            }
        }

        SettingsCard(title: "Report a problem", symbol: "doc.text.magnifyingglass",
                     description: "Save a report you can send for help. It includes system checks and, if selected, one server's recent log. User and computer names, local IPs, and credential-like log lines are removed.") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("What happened? (optional)", text: $description, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
                Picker("Include recent log for", selection: $selectedServerID) {
                    Text("No server log").tag(UUID?.none)
                    ForEach(servers) { server in Text(server.name).tag(Optional(server.id)) }
                }
                Button("Save report…") { Task { await saveReport() } }
                    .cpButton(.primary, size: .sm)
                if let reportStatus { Text(reportStatus).font(.caption).foregroundStyle(CPColor.inkFaint).textSelection(.enabled) }
            }
        }
    }

    private func run() async {
        running = true
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        report = await Doctor.run(servers: servers, appDataDir: dir)
        running = false
    }

    private func saveReport() async {
        reportStatus = "Preparing report…"
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        do {
            let temp = try await ProblemReport.build(description: description, servers: servers,
                                                     selectedServerID: selectedServerID, appDataDir: dir)
            let panel = NSSavePanel()
            panel.title = "Save OMNIServers problem report"
            panel.nameFieldStringValue = temp.lastPathComponent
            panel.allowedContentTypes = [.zip]
            guard panel.runModal() == .OK, let destination = panel.url else {
                try? FileManager.default.removeItem(at: temp)
                reportStatus = "Report not saved."
                return
            }
            try FileManager.default.copyItem(at: temp, to: destination)
            try? FileManager.default.removeItem(at: temp)
            reportStatus = "Saved to \(destination.path)"
        } catch {
            reportStatus = "Could not save report: \(error.localizedDescription)"
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        SettingsCard(title: "OMNIServers", symbol: "info.circle") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    LogoMark(size: 40)
                    VStack(alignment: .leading) {
                        Text("OMNIServers").font(CPFont.display(18, weight: .medium))
                        Text("Version \(Bundle.main.shortVersion) · native macOS")
                            .font(.system(size: 12)).foregroundStyle(CPColor.inkFaint)
                    }
                }
                Text("Run your own Minecraft server — without the config files, the terminal, or the port-forwarding headache.")
                    .font(.system(size: 12)).foregroundStyle(CPColor.inkDim)
                HStack(spacing: 8) {
                    Link("Join the Discord", destination: URL(string: "https://discord.gg/SQwCjE38Jt")!)
                    Link("Source code (GPL-3.0)", destination: URL(string: "https://github.com/Rashica07/OMNIServers")!)
                }
                .font(.system(size: 12))
            }
        }
    }
}
