import SwiftUI

/// In-game chat, natively: who's online, the conversation (plus joins,
/// leaves and advancements), and a box that talks to everyone in-game as
/// "<Host> …". Built from the console stream — no plugin needed.
struct ChatView: View {
    let server: ServerRecord
    let runtime: ServerRuntime

    @State private var draft = ""
    @State private var error: String?
    @State private var follow = true
    @AppStorage("cp.chatName") private var chatName = "Host"

    var body: some View {
        VStack(spacing: 0) {
            onlineStrip
            Divider()
            messages
            Divider()
            composer
        }
        .background(CPColor.surface)
        .task { await runtime.loadChatHistory(serverDir: URL(fileURLWithPath: server.path)) }
    }

    // MARK: - Online

    private var onlineStrip: some View {
        HStack(spacing: 10) {
            Circle().fill(runtime.isRunning ? CPColor.ok : CPColor.inkGhost).frame(width: 7, height: 7)
            Text(runtime.isRunning ? "\(runtime.online.count) online" : "Server offline")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(CPColor.ink)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(runtime.isRunning ? runtime.online : [], id: \.self) { name in
                        HStack(spacing: 5) {
                            PlayerAvatar(name: name, size: 16)
                            Text(name).font(.system(size: 11.5)).foregroundStyle(CPColor.inkDim)
                        }
                        .padding(.leading, 3).padding(.trailing, 8).padding(.vertical, 3)
                        .background(CPColor.surface3, in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    // MARK: - Messages

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if runtime.chat.isEmpty {
                        CPEmptyState(icon: "bubble.left.and.bubble.right", title: "No chat yet",
                                     message: "Messages, joins and advancements from this server show up here live.", compact: true)
                            .padding(.top, 40)
                    }
                    ForEach(runtime.chat) { entry in
                        ChatRow(entry: entry).id(entry.id)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            .background(CPColor.console)
            .onScrollGeometryChange(for: ScrollFollow.self) { geo in
                ScrollFollow(offsetY: geo.contentOffset.y,
                             nearBottom: geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 40)
            } action: { old, new in
                if new.nearBottom { follow = true } else if new.offsetY < old.offsetY - 1 { follow = false }
            }
            .onChange(of: runtime.chat.last?.id) { _, id in
                if follow, let id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onAppear { if let id = runtime.chat.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            .overlay(alignment: .bottomTrailing) {
                if !follow {
                    Button {
                        follow = true
                        if let id = runtime.chat.last?.id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
                    } label: { Label("Jump to latest", systemImage: "arrow.down.to.line") }
                    .cpButton(.primary, size: .sm).padding(10)
                }
            }
        }
    }

    // MARK: - Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error { CPBanner(tone: .bad, message: error) }
            HStack(spacing: 8) {
                TextField(runtime.isRunning ? "Message everyone as <\(effectiveName)>…" : "Start the server to chat", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(CPColor.surface2, in: RoundedRectangle(cornerRadius: CPRadius.md))
                    .overlay(RoundedRectangle(cornerRadius: CPRadius.md).strokeBorder(CPColor.line))
                    .onSubmit { send() }
                    .disabled(!runtime.isRunning)
                Button { send() } label: { Image(systemName: "paperplane.fill") }
                    .cpButton(.primary)
                    .disabled(!runtime.isRunning || draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(10)
    }

    private var effectiveName: String {
        let n = chatName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? "Host" : String(n.prefix(32))
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, runtime.isRunning else { return }
        draft = ""
        error = nil
        Task {
            do { try await runtime.sendChat(text, as: effectiveName, record: server) } catch {
                self.error = error.localizedDescription
                draft = text
            }
        }
    }
}

private struct ChatRow: View {
    let entry: ChatEntry

    var body: some View {
        switch entry.kind {
        case .chat, .mine, .broadcast:
            HStack(alignment: .top, spacing: 8) {
                if entry.kind == .broadcast {
                    Image(systemName: "megaphone.fill").font(.system(size: 11)).foregroundStyle(CPColor.warn).frame(width: 22, height: 22)
                } else {
                    PlayerAvatar(name: entry.who, size: 22)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(entry.kind == .broadcast ? "[\(entry.who)]" : entry.who)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(entry.kind == .mine ? CPColor.accent : PlayerAvatar.color(for: entry.who))
                        if entry.kind == .mine { Text("you").font(.system(size: 10)).foregroundStyle(CPColor.inkFaint) }
                        Text(entry.date, format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundStyle(CPColor.inkGhost)
                    }
                    Text(entry.text).font(.system(size: 13)).foregroundStyle(CPColor.ink).textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
        case .join, .leave, .advancement:
            HStack(spacing: 6) {
                Image(systemName: entry.kind == .join ? "arrow.right.circle.fill" : entry.kind == .leave ? "arrow.left.circle" : "trophy.fill")
                    .foregroundStyle(entry.kind == .join ? CPColor.ok : entry.kind == .leave ? CPColor.inkFaint : CPColor.warn)
                Text(entry.kind == .advancement ? "**\(entry.who)** made the advancement **\(entry.text)**" : "**\(entry.who)** \(entry.text)")
                    .foregroundStyle(CPColor.inkDim)
                Text(entry.date, format: .dateTime.hour().minute()).foregroundStyle(CPColor.inkGhost)
            }
            .font(.system(size: 11.5))
            .padding(.vertical, 3)
            .padding(.leading, 30)
        }
    }
}

/// Initial on a colour picked from the name — stable across launches, no
/// third-party skin service contacted.
struct PlayerAvatar: View {
    let name: String
    var size: CGFloat = 20

    var body: some View {
        Text(String(name.trimmingCharacters(in: CharacterSet(charactersIn: ".*")).prefix(1)).uppercased())
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Self.color(for: name), in: RoundedRectangle(cornerRadius: size * 0.25))
    }

    static func color(for name: String) -> Color {
        var h: UInt32 = 5381
        for b in name.lowercased().utf8 { h = (h &* 33) &+ UInt32(b) }
        return Color(hue: Double(h % 360) / 360, saturation: 0.55, brightness: 0.78)
    }
}
