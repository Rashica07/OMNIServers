import SwiftUI

/// First-run welcome on an empty Overview: three steps and a one-click server.
struct WelcomeCard: View {
    let existing: [ServerRecord]
    let onCreated: (ServerRecord) -> Void
    @Bindable private var router = AppRouter.shared
    @State private var busy = false
    @State private var message = ""
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 18) {
            LogoMark(size: 64)
            VStack(spacing: 6) {
                Text("Host your own Minecraft world").font(CPFont.display(24, weight: .semibold)).foregroundStyle(CPColor.ink)
                Text("OMNIServers runs it on this Mac. Friends join with one address.")
                    .font(.callout).foregroundStyle(CPColor.inkDim).multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 10) {
                step("plus.square.on.square", "Create", "One click gets the latest Minecraft with the right memory.")
                step("play.fill", "Start", "Java is installed for you if it is missing.")
                step("person.2.fill", "Share", "The Network tab shows what friends should type.")
            }
            if busy {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(message).font(.caption).foregroundStyle(CPColor.inkDim)
                }
            } else {
                VStack(spacing: 10) {
                    Button { Task { await create() } } label: {
                        Text("Create my server").font(.system(size: 14, weight: .semibold)).foregroundStyle(CPColor.onAccent)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(CPColor.accent, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    Button { router.showCreate = true } label: {
                        Text("Choose a version, modpack or game mode").frame(maxWidth: .infinity).padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                }
            }
            if !busy {
                Button { OMNILauncherLink.open() } label: {
                    Label("Play Minecraft with OMNI Launcher", systemImage: "cube.fill").font(.callout)
                }
                .buttonStyle(.plain).foregroundStyle(CPColor.inkDim)
                .disabled(OMNILauncherLink.installedURL() == nil)
                .help(OMNILauncherLink.installedURL() == nil ? "OMNI Launcher isn't installed" : "Open OMNI Launcher")
            }
            if let errorText { Text(errorText).font(.caption).foregroundStyle(CPColor.bad) }
        }
        .padding(36)
        .frame(maxWidth: 480)
        .background(CPColor.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(CPColor.line, lineWidth: 1))
    }

    private func step(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(CPColor.accentSoft)
                .frame(width: 30, height: 30)
                .background(CPColor.accentMuted, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(CPColor.ink)
                Text(text).font(.callout).foregroundStyle(CPColor.inkDim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func create() async {
        busy = true; errorText = nil; message = "Getting ready…"
        defer { busy = false }
        do {
            guard let base = CreateServerWizard.defaultServersDir() else { throw ProvisionError.message("Couldn't find your Documents folder.") }
            let rec = try await QuickServer.create(existing: existing, baseDir: base) { p in Task { @MainActor in message = p.message } }
            onCreated(rec)
        } catch { errorText = error.localizedDescription }
    }
}
