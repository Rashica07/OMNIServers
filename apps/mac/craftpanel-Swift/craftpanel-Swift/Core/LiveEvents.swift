import Foundation
import AppKit
import UserNotifications
import Observation

/// Something a player did, read from the server's console output.
nonisolated enum LiveEvent: Sendable, Equatable {
    case join(String)
    case leave(String)
    case chat(from: String, text: String)
    /// `/say` from the console or RCON: "[Server] hi".
    case broadcast(from: String, text: String)
    case advancement(player: String, title: String)

    /// Parses one console line. Handles the vanilla/Fabric
    /// (`[12:00:00] [Server thread/INFO]: …`), Paper (`[12:00:00 INFO]: …`)
    /// and Forge (`… [minecraft/MinecraftServer]: …`) prefixes, ANSI colour
    /// codes, and 1.19+'s "[Not Secure]" chat marker. Names are validated
    /// so a chat message can't forge a join.
    static func parse(_ raw: String) -> LiveEvent? {
        let line = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let body: Substring
        if let r = line.range(of: "]: ") {
            body = line[r.upperBound...]
        } else if let r = line.range(of: #"^\[\d{2}:\d{2}:\d{2}\] "#, options: .regularExpression) {
            body = line[r.upperBound...]   // OMNIHost's short console format
        } else { return nil }
        var rest = body.trimmingCharacters(in: .whitespaces)[...]
        if rest.hasPrefix("[Not Secure] ") { rest = rest.dropFirst("[Not Secure] ".count) }

        if rest.hasPrefix("<"), let close = rest.firstIndex(of: ">") {
            let name = rest[rest.index(after: rest.startIndex)..<close]
            let text = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
            guard isValidName(name), !text.isEmpty else { return nil }
            return .chat(from: String(name), text: text)
        }
        if rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
            let who = rest[rest.index(after: rest.startIndex)..<close]
            if who == "Server" || who == "Rcon" {
                let text = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
                return text.isEmpty ? nil : .broadcast(from: String(who), text: text)
            }
            return nil
        }
        for suffix in [" joined the game", " left the game"] where rest.hasSuffix(suffix) {
            let name = rest.dropLast(suffix.count)
            guard isValidName(name) else { return nil }
            return suffix == " joined the game" ? .join(String(name)) : .leave(String(name))
        }
        for verb in [" has made the advancement [", " has completed the challenge [", " has reached the goal ["] {
            if let v = rest.range(of: verb), rest.hasSuffix("]") {
                let name = rest[..<v.lowerBound]
                guard isValidName(name) else { return nil }
                return .advancement(player: String(name), title: String(rest[v.upperBound..<rest.index(before: rest.endIndex)]))
            }
        }
        return nil
    }

    /// Java names (3–16 of A–Z, 0–9, _) plus Geyser/Floodgate's "." or
    /// "*" prefix for Bedrock players.
    static func isValidName(_ n: Substring) -> Bool {
        var s = n
        if let f = s.first, f == "." || f == "*" { s = s.dropFirst() }
        return (1...16).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}

/// One row in a server's Chat tab.
nonisolated struct ChatEntry: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case chat, broadcast, join, leave, advancement, mine }
    let id: UInt64
    let date: Date
    let kind: Kind
    let who: String
    let text: String
}

/// Where join/leave/chat notices go: a macOS notification when OMNIServers
/// is in the background, our own toast when you're looking at it. Also
/// keeps the Dock badge at the total number of players online.
@MainActor @Observable
final class PlayerNotifier {
    static let shared = PlayerNotifier()

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        let serverID: UUID
        let title: String
        let subtitle: String
        let symbol: String
    }

    private(set) var toasts: [Toast] = []
    @ObservationIgnored private var online: [UUID: Int] = [:]
    @ObservationIgnored private var askedPermission = false

    func setOnline(_ serverID: UUID, count: Int) {
        online[serverID] = count
        let total = online.values.reduce(0, +)
        guard !isRunningUnitTests else { return }
        NSApp?.dockTile.badgeLabel = total > 0 ? "\(total)" : nil
    }

    var totalOnline: Int { online.values.reduce(0, +) }

    func handle(_ event: LiveEvent, serverID: UUID, serverName: String, onlineCount: Int) {
        let (title, symbol): (String, String)
        switch event {
        case .join(let p):
            guard AppDefaults.notifyJoins else { return }
            (title, symbol) = ("\(p) joined", "person.crop.circle.badge.plus")
        case .leave(let p):
            guard AppDefaults.notifyJoins else { return }
            (title, symbol) = ("\(p) left", "person.crop.circle.badge.minus")
        case .chat(let p, let text):
            guard AppDefaults.notifyChat else { return }
            (title, symbol) = ("\(p): \(text)", "bubble.left")
        case .advancement(let p, let t):
            guard AppDefaults.notifyJoins else { return }
            (title, symbol) = ("\(p) got [\(t)]", "trophy")
        case .broadcast:
            return
        }
        let subtitle = "\(serverName) · \(onlineCount) online"
        if !isRunningUnitTests, NSApp?.isActive == true {
            let toast = Toast(serverID: serverID, title: title, subtitle: subtitle, symbol: symbol)
            toasts.append(toast)
            if toasts.count > 4 { toasts.removeFirst(toasts.count - 4) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                self.dismiss(toast.id)
            }
        } else {
            post(title: title, body: subtitle, serverID: serverID)
        }
    }

    func dismiss(_ id: UUID) { toasts.removeAll { $0.id == id } }

    private func post(title: String, body: String, serverID: UUID) {
        guard !isRunningUnitTests else { return }
        let center = UNUserNotificationCenter.current()
        if !askedPermission {
            askedPermission = true
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = serverID.uuidString
        content.userInfo = ["serverID": serverID.uuidString]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

/// Clicking a player notification opens that server's Chat tab.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let s = response.notification.request.content.userInfo["serverID"] as? String, let id = UUID(uuidString: s) else { return }
        await MainActor.run {
            NSApp.activate()
            AppRouter.shared.destination = .server(id, .chat)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// Tails `logs/latest.log` for a server OMNIServers re-adopted after a
/// restart (no stdout pipe then), so its console, chat and join
/// notifications keep working. Starts at the current end of the file and
/// follows log rotation.
nonisolated struct LogTailer: Sendable {
    let file: URL
    private(set) var offset: UInt64
    private var partial = Data()

    init(serverDir: URL) {
        file = serverDir.appending(path: "logs/latest.log")
        offset = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? UInt64) ?? 0
    }

    /// New complete lines since the last call.
    mutating func poll() -> [String] {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? UInt64) else { return [] }
        if size < offset { offset = 0; partial = Data() }   // rotated
        guard size > offset, let h = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        let data = (try? h.read(upToCount: Int(min(size - offset, 1 << 20)))) ?? Data()
        offset += UInt64(data.count)
        partial.append(data)
        guard let lastNL = partial.lastIndex(of: 0x0A) else { return [] }
        let complete = partial[partial.startIndex...lastNL]
        partial = Data(partial[partial.index(after: lastNL)...])
        return String(decoding: complete, as: UTF8.self).split(separator: "\n").map { String($0).trimmingCharacters(in: .newlines) }
    }
}

nonisolated enum ChatHistory {
    struct Past: Sendable { let date: Date; let kind: ChatEntry.Kind; let who: String; let text: String }

    /// Chat/joins/advancements from the tail of `logs/latest.log` (today's
    /// session), oldest first.
    static func load(serverDir: URL, maxBytes: Int = 256 * 1024) -> [Past] {
        let file = serverDir.appending(path: "logs/latest.log")
        guard let h = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
        let text = String(decoding: (try? h.readToEnd()) ?? Data(), as: UTF8.self)
        let day = Calendar.current.startOfDay(for: (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date())
        var out: [Past] = []
        for line in text.split(separator: "\n") {
            guard let ev = LiveEvent.parse(String(line)) else { continue }
            let date = time(String(line)).map { day.addingTimeInterval($0) } ?? day
            switch ev {
            case .join(let p): out.append(.init(date: date, kind: .join, who: p, text: "joined the game"))
            case .leave(let p): out.append(.init(date: date, kind: .leave, who: p, text: "left the game"))
            case .chat(let p, let t): out.append(.init(date: date, kind: .chat, who: p, text: t))
            case .broadcast(let w, let t): out.append(.init(date: date, kind: .broadcast, who: w, text: t))
            case .advancement(let p, let t): out.append(.init(date: date, kind: .advancement, who: p, text: t))
            }
        }
        return Array(out.suffix(300))
    }

    /// "[12:34:56…" → seconds since midnight.
    static func time(_ line: String) -> TimeInterval? {
        let c = Array(line.prefix(9))
        guard c.count == 9, c[0] == "[", c[3] == ":", c[6] == ":",
              let h = Int(String(c[1...2])), let m = Int(String(c[4...5])), let s = Int(String(c[7...8])) else { return nil }
        return TimeInterval(h * 3600 + m * 60 + s)
    }

    /// `["",{"text":"<Host> ","color":"gold"},{"text":"hi"}]` — JSON-encoded
    /// so quotes, backslashes and newlines in the message can't break out.
    static func tellrawJSON(name: String, message: String) -> String {
        let clean = message.replacingOccurrences(of: "\n", with: " ")
        let parts: [Any] = ["", ["text": "<\(name)> ", "color": "gold"], ["text": clean]]
        let data = (try? JSONSerialization.data(withJSONObject: parts, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
