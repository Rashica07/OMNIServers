import Foundation
import Observation

/// Lets the menu bar, the menu-bar extra and the command palette drive the
/// main window (open a sheet, jump to a server) without owning its state.
@MainActor @Observable
final class AppRouter {
    static let shared = AppRouter()

    enum Destination: Equatable {
        case overview
        case settings
        case server(UUID, ServerSection?)
    }

    var showCreate = false
    /// Open the create wizard straight in "modpack" mode.
    var createAsModpack = false
    var showQuickStart = false
    var showAddFolder = false
    var showPalette = false
    var showHelp = false
    var helpContext = "overview"
    /// The server tab currently on screen (nil when no server page is showing); lets Help open on the right topic.
    var currentSection: String?
    /// Set by ServerListView whenever its selection changes; read by menus.
    var selectedServerID: UUID?
    /// A pending navigation request; ServerListView consumes and clears it.
    var destination: Destination?
}
