import Foundation
import AppKit

/// What the "Join" button does. Bedrock has a link that adds the server and opens the game; Java has none in the official launcher.
nonisolated struct JoinPlan: Equatable, Sendable {
    var bedrock: Bool
    var uri: String?
    var address: String
}

nonisolated enum JoinLink {
    static func plan(isBedrock: Bool, name: String, address: String) -> JoinPlan {
        guard isBedrock else { return JoinPlan(bedrock: false, uri: nil, address: address) }
        let enc = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "|&=+"))) ?? name
        return JoinPlan(bedrock: true, uri: "minecraft://?addExternalServer=\(enc)|\(address)", address: address)
    }

    static let javaLauncher = URL(fileURLWithPath: "/Applications/Minecraft.app")

    /// Opens the game for this plan; true when something opened.
    @MainActor
    static func open(_ plan: JoinPlan) -> Bool {
        if let uri = plan.uri, let url = URL(string: uri) { return NSWorkspace.shared.open(url) }
        guard FileManager.default.fileExists(atPath: javaLauncher.path) else { return false }
        return NSWorkspace.shared.open(javaLauncher)
    }
}
