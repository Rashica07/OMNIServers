import SwiftUI
import AppKit

/// Network tab: optional Playit.gg address. The agent only runs while a server that opted in is running.
struct PlayitCard: View {
    let server: ServerRecord
    @Environment(ProcessManager.self) private var processes
    @State private var enabled: Bool
    @State private var signingIn = false
    @State private var signInError: String?
    private var agent: PlayitAgent { PlayitAgent.shared }

    init(server: ServerRecord) {
        self.server = server
        _enabled = State(initialValue: PlayitSettings.isEnabled(server.id))
    }

    private var port: Int { Int(NetworkInfo.port(serverDir: URL(fileURLWithPath: server.path))) }
    private var status: ServerStatus { processes.runtime(for: server.id).snapshot.status }
    private var address: String? { agent.address(forPort: port) }
    private var needsSignIn: Bool { enabled && (agent.phase == .needsClaim || !PlayitClaim.hasSecret) }

    var body: some View {
        SettingsCard(title: "Playit.gg address", symbol: "network",
                     description: server.serverType.isBedrock
                        ? "A public address for Bedrock players. Playit runs only while this server runs."
                        : "A public address friends can use from anywhere. Playit runs only while this server runs, then stops.") {
            Toggle("Use Playit for this server", isOn: Binding(get: { enabled }, set: setEnabled))
                .toggleStyle(.switch)
            if enabled {
                if needsSignIn {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Link your free Playit account once. Your browser opens, you approve, and you're done.")
                            .font(.callout).foregroundStyle(CPColor.inkDim)
                        Button(signingIn ? "Waiting for you in the browser…" : "Sign in to Playit") { Task { await signIn() } }
                            .cpButton(.primary, size: .sm).disabled(signingIn)
                    }
                } else {
                    HStack(spacing: 8) {
                        Label(statusText, systemImage: statusSymbol)
                            .font(.callout).foregroundStyle(statusColor)
                        Spacer()
                        if let a = address {
                            Button("Copy address") { Toasts.shared.copy(a, what: "Address", detail: "Paste it to your friends") }
                                .cpButton(.secondary, size: .sm)
                        }
                    }
                }
                if let e = signInError { Text(e).font(.caption).foregroundStyle(CPColor.bad) }
                if case .error(let m) = agent.phase { Text(m).font(.caption).foregroundStyle(CPColor.bad) }
            }
        }
    }

    private var statusText: String {
        if let a = address { return a }
        if status == .stopped || status == .crashed { return "Starts with the server" }
        return agent.phase.label
    }
    private var statusSymbol: String { address != nil ? "checkmark.circle.fill" : "circle.dashed" }
    private var statusColor: Color { address != nil ? CPColor.ok : CPColor.inkFaint }

    private func setEnabled(_ on: Bool) {
        enabled = on
        PlayitSettings.setEnabled(server.id, on)
        // Already running? Join or leave the agent now rather than at the next start.
        if on { PlayitCoordinator.shared.statusChanged(serverID: server.id, status: status) }
        else { agent.release(server.id) }
    }

    private func signIn() async {
        signingIn = true; signInError = nil
        defer { signingIn = false }
        do {
            try await PlayitBinary.install()
            let started = try await PlayitClaim.begin()
            NSWorkspace.shared.open(started.url)
            let secret = try await PlayitClaim.exchange(code: started.code)
            Keychain.set(PlayitClaim.keychainAccount, secret)
            // Restart the agent so it picks the account up (only if a server is using it right now).
            if status == .running || status == .starting {
                agent.release(server.id)
                try? await Task.sleep(for: .milliseconds(500))
                PlayitCoordinator.shared.statusChanged(serverID: server.id, status: status)
            }
        } catch { signInError = error.localizedDescription }
    }
}
