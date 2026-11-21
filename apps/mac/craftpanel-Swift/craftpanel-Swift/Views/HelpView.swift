import SwiftUI

private struct HelpArticle: Identifiable {
    let id: String
    let title: String
    let summary: String
    let steps: [String]
    let keywords: String
}

/// Works out which Help topic matches what is on screen.
enum HelpContext {
    static func topic(settings: Bool, overview: Bool, section: String?) -> String {
        if settings { return "diagnostics" }
        if overview { return "overview" }
        switch section {
        case "network": return "network"
        case "players": return "players"
        case "worlds": return "worlds"
        case "backups": return "backups"
        case "files": return "files"
        case "addons", "mods", "resourcepacks": return "mods"
        case "settings": return "start"
        case "performance": return "low-spec"
        default: return "start"
        }
    }
}

private enum HelpLibrary {
    static let articles: [HelpArticle] = [
        .init(id: "overview", title: "Get around OMNIServers", summary: "Overview, servers, and settings", steps: ["Overview shows the servers OMNIServers manages and their status.", "Choose a server in the sidebar, then use its tabs to manage it.", "OMNIServers settings at the bottom of the sidebar contains app-wide preferences."], keywords: "overview sidebar navigation"),
        .init(id: "start", title: "Start, stop, and share a server", summary: "The safe basics for hosting", steps: ["Select a server and press Start. Keep OMNIServers open while it starts.", "Use Stop to shut down cleanly; avoid Force Kill unless it is unresponsive.", "Use Network → Invite to copy connection details. Guests generally need the same Wi-Fi unless the host has configured remote access."], keywords: "start stop server invite hosting"),
        .init(id: "worlds", title: "Move a world to this server", summary: "Import, switch, and export worlds", steps: ["Stop the server before changing worlds.", "Open Worlds → Choose folder or .zip, or drag a world onto the page.", "OMNIServers copies the source and leaves the original untouched. Review the Minecraft version notice before starting.", "Use Export beside a world to create a .zip backup."], keywords: "world import export save singleplayer folder zip"),
        .init(id: "network", title: "Invite players on a LAN", summary: "Share the right address and request network access", steps: ["Start the server and open Network.", "Copy the invite card for your server edition and port.", "On school or guest Wi-Fi, devices may be isolated. Copy the access request and give it to the network administrator; OMNIServers cannot change school network policy."], keywords: "lan wifi school invite firewall port"),
        .init(id: "public", title: "Let friends outside your Wi-Fi join", summary: "Make a server public with the free tunnel", steps: ["Start the server, then open the Network tab.", "Under Free tunnel, press Start Tunnel. Java servers get one automatically when the server starts.", "Copy the bore.pub address that appears and send it to your friends. It changes each time the tunnel restarts.", "Bedrock servers can't use the free tunnel. Forward the UDP port on your router instead, or use a hosting provider.", "Only share the address with people you trust, and keep the allow-list on."], keywords: "public internet outside non lan tunnel bore friends remote port forward"),
        .init(id: "backups", title: "Back up and restore a world", summary: "Protect server files before risky changes", steps: ["Stop the server before creating or restoring a backup.", "Open Backups and create a backup before installing add-ons or changing versions.", "Restore only after checking the selected server and backup date."], keywords: "backup restore"),
        .init(id: "low-spec", title: "Help a slower Mac", summary: "Light mode and a low-spec server preset", steps: ["OMNIServers enables Light mode by default on a lower-memory Mac; change it in OMNIServers settings → General.", "For Java servers, open server Settings and choose a low-spec preset.", "Apply the preset while the server is stopped. It adjusts view distances and a safe memory suggestion; you can review changes before starting."], keywords: "slow low spec old mac performance memory light mode"),
        .init(id: "report", title: "Send a problem report safely", summary: "Create a redacted support bundle", steps: ["Open OMNIServers settings → Diagnostics.", "Optionally choose a server and describe the problem, then select Save report.", "Review the ZIP before sharing it. The report removes common local identifiers and excludes world files."], keywords: "diagnostics report crash help support privacy"),
        .init(id: "java", title: "Fix Java startup problems", summary: "Check Java and the server log", steps: ["Open OMNIServers settings → Java and run the Java check.", "Make sure the selected Java version matches the Minecraft server version.", "If startup still fails, open Console and Diagnostics; include a problem report when asking for help."], keywords: "java startup version console"),
        .init(id: "files", title: "Use server files safely", summary: "Find files without changing the wrong server", steps: ["Select the intended server and open Files.", "Stop the server before replacing configuration or world files.", "Keep a backup before making manual edits."], keywords: "files config edit"),
        .init(id: "players", title: "Manage players", summary: "Allow-list and operator access", steps: ["Open Players for the selected server.", "Only grant operator access to people you trust; it allows powerful commands.", "Use the allow-list controls to limit who can join."], keywords: "players whitelist allowlist operator ops"),
        .init(id: "mods", title: "Install add-ons or mods", summary: "Check server type and compatibility", steps: ["Open Add-ons or Mods for the selected server.", "Check that the item supports this server type and Minecraft version.", "Create a backup first and stop the server before applying changes."], keywords: "mods plugins addons modrinth"),
        .init(id: "diagnostics", title: "Run a health check", summary: "Find common setup problems", steps: ["Open OMNIServers settings → Diagnostics.", "Run the health check and expand any warning for details.", "Use the generated problem report when sharing diagnostics; avoid posting private logs publicly."], keywords: "doctor health check diagnostics"),
        .init(id: "security", title: "Keep your server safer", summary: "Network access and permissions", steps: ["Share invites only with people you intend to let in.", "Avoid exposing the server port publicly unless you understand the router and firewall settings.", "Use the school network request card for managed networks; only an administrator can approve it."], keywords: "security firewall school permissions"),
    ]
    static let tour = ["Choose Overview to see your servers.", "Select a server and use its tabs to manage players, worlds, backups, and network invites.", "Stop the server before changing worlds, installing add-ons, or restoring backups.", "Open OMNIServers settings for diagnostics, Light mode, and problem reports.", "Use Help & Tutorial from the Help menu whenever you need a step-by-step guide."]
}

struct HelpView: View {
    let context: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var mode: String
    @State private var selectedID: String?
    @State private var tourIndex = 0

    init(context: String) {
        self.context = context
        _mode = State(initialValue: context == "tour" ? "Full tutorial" : "This page")
    }

    private var visible: [HelpArticle] {
        let matches = HelpLibrary.articles.filter {
            query.isEmpty || "\($0.title) \($0.summary) \($0.keywords) \($0.steps.joined(separator: " "))".localizedCaseInsensitiveContains(query)
        }
        return mode == "This page" && query.isEmpty ? matches.filter { $0.id == context || (context == "network" && $0.id == "public") || (context.hasPrefix("settings") && ["low-spec", "report", "diagnostics", "java"].contains($0.id)) } : matches
    }
    private var selected: HelpArticle? { visible.first { $0.id == (selectedID ?? visible.first?.id) } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("OMNIServers Help", systemImage: "questionmark.circle").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding()
            Picker("Help", selection: $mode) { Text("This page").tag("This page"); Text("Full tutorial").tag("Full tutorial"); Text("How do I…").tag("How do I…") }
                .pickerStyle(.segmented).padding(.horizontal)
            if mode != "Full tutorial" {
                TextField("Search help", text: $query).textFieldStyle(.roundedBorder).padding()
                HStack(alignment: .top, spacing: 16) {
                    List(visible) { article in Button(article.title) { selectedID = article.id }.buttonStyle(.plain) }
                        .frame(width: 210)
                    ScrollView {
                        if let selected {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(selected.title).font(.title2.bold())
                                Text(selected.summary).foregroundStyle(.secondary)
                                ForEach(Array(selected.steps.enumerated()), id: \.offset) { index, step in Label(step, systemImage: "\(index + 1).circle") }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding()
                        } else { ContentUnavailableView("No matching help", systemImage: "magnifyingglass") }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    Text("A quick tour").font(.title2.bold())
                    ForEach(Array(HelpLibrary.tour.enumerated()), id: \.offset) { index, step in
                        Label(step, systemImage: "\(index + 1).circle")
                    }
                    HStack { Spacer(); Button("Got it") { AppDefaults.helpTourSeen = true; dismiss() }.cpButton(.primary) }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .onChange(of: mode) { _, _ in selectedID = nil }
        .onChange(of: query) { _, _ in selectedID = nil }
    }
}
