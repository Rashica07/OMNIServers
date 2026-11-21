import SwiftUI
import AppKit

/// "Play the same world on two computers" — folder-based sharing only
/// (a server folder that already lives in iCloud Drive/Dropbox/SMB gets
/// an advisory lease so two devices never run it at once). Direct port
/// of `ShareSection.tsx`'s folder-share half — the cloud/R2 half isn't
/// built (cloud sync itself isn't wired into this app).
struct ShareCard: View {
    let server: ServerRecord

    @State private var view: ShareView?
    @State private var busy = false
    @State private var errorText: String?
    @State private var copied = false

    private var root: URL { URL(fileURLWithPath: server.path) }

    var body: some View {
        SettingsCard(title: "Play the same world on two computers", symbol: "arrow.left.arrow.right",
                     description: "Hand the world back and forth with a friend, or between your own machines, via a folder you already keep in iCloud/Dropbox.") {
            if let view, view.shared {
                sharedBody(view)
            } else {
                Button(busy ? "Sharing…" : "Share via Synced Folder") {
                    Task { await share() }
                }
                .cpButton(.primary)
                .disabled(busy)
            }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(CPColor.warn)
            }
        }
        .task(id: server.id) { reload() }
    }

    @ViewBuilder
    private func sharedBody(_ v: ShareView) -> some View {
        HStack(spacing: 8) {
            Text("Code").font(.caption).foregroundStyle(CPColor.inkFaint)
            Text(v.code ?? "").font(.system(.body, design: .monospaced).weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(CPColor.surface2).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            Button(copied ? "Copied" : "Copy") { copy(v.code ?? "") }
            leaseBadge(v)
        }
        Text("Synced-folder mode. On the other device: point OMNIServers at this same folder, then enter this code.")
            .font(.caption2).foregroundStyle(CPColor.inkFaint)
        Button("Stop Sharing", role: .destructive) {
            Task { await unshare() }
        }
        .disabled(busy)
    }

    private func leaseBadge(_ v: ShareView) -> some View {
        let (text, tone): (String, Color) = {
            if v.heldByUs { return ("You have the lease", CPColor.ok) }
            if v.locked {
                let mins = max(0, (v.expiresIn ?? 0) / 60)
                return ("In use on \(v.holderName ?? "another device") · ~\(mins)m", CPColor.warn)
            }
            return ("Available", CPColor.ok)
        }()
        return Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(tone.opacity(0.15)).foregroundStyle(tone)
            .clipShape(Capsule())
    }

    private func reload() {
        view = ShareLease.view(dir: root, deviceID: ShareLease.thisDeviceID)
    }

    private func share() async {
        busy = true; errorText = nil
        defer { busy = false }
        do {
            _ = try ShareLease.createShare(dir: root, name: server.name)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func unshare() async {
        busy = true; errorText = nil
        defer { busy = false }
        do {
            try ShareLease.unshare(dir: root, deviceID: ShareLease.thisDeviceID)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func copy(_ text: String) {
        Toasts.shared.copy(text, what: "Link")
        copied = true
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            copied = false
        }
    }
}
