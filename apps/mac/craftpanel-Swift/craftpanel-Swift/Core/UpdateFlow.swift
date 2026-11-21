import AppKit

/// Keeps OMNIServers up to date without the user hunting for it. On launch it checks GitHub and shows an alert: update now, update when
/// the app quits, or later. Also installs and updates OMNI Launcher on request.
@MainActor
final class UpdateFlow {
    static let shared = UpdateFlow()
    private var stagedForQuit: URL?
    private var launcherDeclined = false
    private var launcherUpdateAsked = false

    // MARK: - OMNIServers

    /// Called shortly after launch with the check result. Shows the alert; does nothing when there is no installable update.
    func offer(_ update: UpdateCheck, serversRunning: Bool) async {
        guard !isRunningUnitTests, update.newer, let dmg = update.downloadURL else { return }
        let alert = NSAlert()
        alert.messageText = "OMNIServers \(update.latest ?? "") is available"
        var text = "You have \(update.current). "
        text += serversRunning
            ? "Updating now stops your servers safely (worlds are saved first) and restarts OMNIServers. "
            : "Updating now restarts OMNIServers. "
        text += "“When I quit” installs it the next time you close the app."
        if let notes = update.notes, !notes.isEmpty { text += "\n\n" + notes }
        alert.informativeText = text
        alert.addButton(withTitle: "Update now")
        alert.addButton(withTitle: "When I quit")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn: await installNow(dmg: dmg)
        case .alertSecondButtonReturn: await stageForQuit(dmg: dmg, version: update.latest ?? "")
        default: break
        }
    }

    func installNow(dmg: URL) async {
        do {
            Toasts.shared.show("Downloading the update…", symbol: "arrow.down.circle.fill")
            let staged = try await UpdateInstaller.prepare(dmg: dmg) { _ in }
            guard UpdateInstaller.canReplaceInPlace() else { revealManualInstall(staged); return }
            try UpdateInstaller.swapAndRelaunch(staged: staged)
            NSApp.terminate(nil)
        } catch {
            Toasts.shared.error("The update didn't install", detail: error.localizedDescription)
        }
    }

    func stageForQuit(dmg: URL, version: String) async {
        do {
            Toasts.shared.show("Downloading the update…", detail: "It installs when you quit", symbol: "arrow.down.circle.fill")
            let staged = try await UpdateInstaller.prepare(dmg: dmg) { _ in }
            guard UpdateInstaller.canReplaceInPlace() else { revealManualInstall(staged); return }
            stagedForQuit = staged
            Toasts.shared.show("OMNIServers \(version) is ready", detail: "It installs when you quit", symbol: "arrow.down.circle.fill")
        } catch {
            Toasts.shared.error("Couldn't download the update", detail: error.localizedDescription)
        }
    }

    /// Called as the app terminates: starts the swap that puts the staged update in place once this process is gone.
    func applyOnQuit() {
        guard let staged = stagedForQuit else { return }
        stagedForQuit = nil
        try? UpdateInstaller.swapAndRelaunch(staged: staged, relaunch: false)
    }

    private func revealManualInstall(_ staged: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([staged.appending(path: "OMNIServers.app")])
        Toasts.shared.error("This copy can't replace itself where it is", detail: "The new OMNIServers is selected in Finder: drag it into Applications.")
    }

    // MARK: - OMNI Launcher

    /// Makes sure OMNI Launcher is installed before something opens it. Not installed: asks, then downloads the latest build from GitHub and
    /// installs it. Installed by this app and a newer build exists: offers the update once per run. True when a launcher is ready to open.
    func ensureLauncher() async -> Bool {
        let existing = OMNILauncherLink.installedURL()
        if existing == nil, !OMNILauncherLink.isRunning() {
            if launcherDeclined { return false }
            guard LauncherInstaller.platform != nil else {
                let a = NSAlert()
                a.messageText = "OMNI Launcher isn't available for this Mac yet"
                a.informativeText = "So far the launcher is built for Apple silicon Macs only."
                a.runModal()
                return false
            }
            let a = NSAlert()
            a.messageText = "OMNI Launcher isn't installed"
            a.informativeText = "OMNI Launcher is the Minecraft launcher that goes with OMNIServers. Download the latest version from GitHub and install it for you?"
            a.addButton(withTitle: "Download and install")
            a.addButton(withTitle: "Not now")
            guard a.runModal() == .alertFirstButtonReturn else { launcherDeclined = true; return false }
            return await installLauncher(existing: nil, updating: false)
        }
        if let existing, !launcherUpdateAsked, !OMNILauncherLink.isRunning() {
            launcherUpdateAsked = true
            if let latest = try? await LauncherInstaller.latest(),
               LauncherInstaller.isUpdateAvailable(installedTag: LauncherInstaller.installedTag, latestTag: latest.tag) {
                let a = NSAlert()
                a.messageText = "A newer OMNI Launcher is available"
                a.informativeText = "Update OMNI Launcher to \(latest.tag.replacingOccurrences(of: "omni-launcher-", with: "")) now?"
                a.addButton(withTitle: "Update")
                a.addButton(withTitle: "Not now")
                if a.runModal() == .alertFirstButtonReturn { _ = await installLauncher(existing: existing, updating: true) }
            }
        }
        return true
    }

    private func installLauncher(existing: URL?, updating: Bool) async -> Bool {
        do {
            Toasts.shared.show(updating ? "Updating OMNI Launcher…" : "Downloading OMNI Launcher…", detail: "This takes a moment", symbol: "arrow.down.circle.fill")
            let release = try await LauncherInstaller.latest()
            _ = try await LauncherInstaller.download(release, existing: existing) { _ in }
            Toasts.shared.show(updating ? "OMNI Launcher updated" : "OMNI Launcher installed", detail: release.tag.replacingOccurrences(of: "omni-launcher-", with: ""))
            return true
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't install OMNI Launcher"
            a.informativeText = error.localizedDescription
            a.runModal()
            return false
        }
    }

    /// The "Open launcher" buttons: installs it first when it isn't there, then opens it.
    func openLauncher() async {
        guard await ensureLauncher() else { return }
        OMNILauncherLink.open()
    }
}
