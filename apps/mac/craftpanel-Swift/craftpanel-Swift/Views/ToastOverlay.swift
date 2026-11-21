import SwiftUI

/// In-app player notices (joins, leaves, advancements) — shown instead of
/// a macOS notification while you're using OMNIServers. Click to open that
/// server's Chat tab.
struct ToastOverlay: View {
    @State private var notifier = PlayerNotifier.shared
    @State private var notices = Toasts.shared

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(notices.items) { n in
                HStack(spacing: 10) {
                    Image(systemName: n.symbol).font(.system(size: 14))
                        .foregroundStyle(n.isError ? CPColor.warn : CPColor.ok).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(n.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(CPColor.ink).lineLimit(2)
                        if !n.detail.isEmpty { Text(n.detail).font(.system(size: 11)).foregroundStyle(CPColor.inkFaint).lineLimit(2) }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(width: 280)
                .background(CPColor.surface2, in: RoundedRectangle(cornerRadius: CPRadius.lg))
                .overlay(RoundedRectangle(cornerRadius: CPRadius.lg).strokeBorder(CPColor.line))
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                .onTapGesture { notices.dismiss(n.id) }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            ForEach(notifier.toasts) { t in
                Button {
                    AppRouter.shared.destination = .server(t.serverID, .chat)
                    notifier.dismiss(t.id)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: t.symbol).font(.system(size: 15)).foregroundStyle(CPColor.accent).frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(CPColor.ink).lineLimit(2)
                            Text(t.subtitle).font(.system(size: 11)).foregroundStyle(CPColor.inkFaint)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .frame(width: 280)
                    .background(CPColor.surface2, in: RoundedRectangle(cornerRadius: CPRadius.lg))
                    .overlay(RoundedRectangle(cornerRadius: CPRadius.lg).strokeBorder(CPColor.line))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(14)
        .animation(.spring(duration: 0.3), value: notifier.toasts)
        .animation(.spring(duration: 0.3), value: notices.items)
    }
}
