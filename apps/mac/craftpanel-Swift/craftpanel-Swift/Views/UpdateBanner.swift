import SwiftUI

/// Runs an `UpdateChecker.check()` once when it first appears and shows a
/// dismissible banner if something newer is out — the "checks on launch
/// like a game launcher" behavior, with no blocking splash and no
/// modal interrupting startup. Silent when there's nothing to report:
/// offline, no releases yet, or already current all render nothing.
struct UpdateBanner: View {
    @State private var result: UpdateCheck?
    @State private var dismissed = false

    var body: some View {
        Group {
            if let result, result.newer, !dismissed {
                banner(for: result)
            }
        }
        .task {
            guard AppDefaults.autoCheckUpdates, !isRunningUnitTests else { return }
            let r = await UpdateChecker.check()
            // An installable update gets the alert (update now / when I quit / later). Without a download for this Mac, the banner links to the release.
            if r.newer, r.downloadURL != nil {
                try? await Task.sleep(for: .seconds(1.5))
                await UpdateFlow.shared.offer(r, serversRunning: AppDelegate.shared?.processes.anyRunning ?? false)
            } else {
                result = r
            }
        }
    }

    private func banner(for update: UpdateCheck) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.tint)
                .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("OMNIServers \(update.latest ?? "") is available")
                        .font(CPFont.display(13, weight: .semibold))
                        .foregroundStyle(CPColor.ink)
                    Text("you have \(update.current)")
                        .font(.caption)
                        .foregroundStyle(CPColor.inkFaint)
                }
                if let notes = update.notes, !notes.isEmpty {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(CPColor.inkFaint)
                        .lineLimit(3)
                }
            }

            Spacer(minLength: 12)

            if let url = update.url {
                Link(destination: url) {
                    Text("View Release")
                }
                .cpButton(.primary, size: .sm)
            }

            IconButton(systemName: "xmark", size: 24, tint: .secondary) {
                withAnimation(.easeOut(duration: 0.15)) { dismissed = true }
            }
        }
        .padding(10)
        .background(CPColor.accent.opacity(0.12))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
