using System.Diagnostics;
using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using CraftPanel.Core;
using CraftPanel.Core.Network;
using CraftPanel.Core.Updates;

namespace CraftPanel.App.Services;

/// <summary>
/// Keeps OMNIServers up to date without the user hunting for it: on launch it checks GitHub and shows an alert; the user can update right away,
/// have it installed when they quit, or skip. Also installs and updates OMNI Launcher on request.
/// </summary>
public static class UpdateFlow
{
    static string? _stagedForQuit;
    static bool _launcherAsked, _launcherDeclined;

    /// <summary>Called once the main window is up. Silent when offline, already current, or this copy can't replace itself.</summary>
    public static async Task OfferOnLaunchAsync(string currentVersion)
    {
        if (Environment.ProcessPath is not { } exe) return;
        var info = await AppUpdater.CheckAsync(currentVersion);
        if (info is not { Newer: true, ZipUrl: not null }) return;
        if (!AppUpdater.CanReplace(exe))
        {
            ToastService.Shared.Show($"OMNIServers {info.Latest} is available", "This folder isn't writable, so download it from the Releases page", "download", "ok", null, 10);
            return;
        }
        var running = AppServices.Processes.AnyRunning;
        var notes = string.IsNullOrWhiteSpace(info.Notes) ? "" : "\n\n" + info.Notes;
        var msg = $"You have {currentVersion}. {(running ? "Updating now stops your servers safely (worlds are saved first) and restarts OMNIServers." : "Updating now restarts OMNIServers.")} \"When I quit\" installs it the next time you close the app.{notes}";
        switch (await Dialogs.Current.ChooseAsync($"OMNIServers {info.Latest} is available", msg, "Update now", "When I quit", "Later"))
        {
            case 0: await InstallNowAsync(info); break;
            case 1: await StageForQuitAsync(info); break;
        }
    }

    public static async Task InstallNowAsync(UpdateInfo info)
    {
        if (Environment.ProcessPath is not { } exe) return;
        try
        {
            ToastService.Shared.Show("Downloading the update…", $"OMNIServers {info.Latest}", "download", "ok", null, 60);
            var staged = await AppUpdater.StageAsync(info, exe);
            AppUpdater.Swap(exe, staged);
            Process.Start(new ProcessStartInfo(exe, AppUpdater.WaitArg) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(exe)! });
            (Application.Current?.ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)?.Shutdown();
        }
        catch (Exception e) { ToastService.Shared.Error("The update didn't install: " + e.Message); }
    }

    /// <summary>Downloads the update now and swaps it in when the app quits.</summary>
    public static async Task StageForQuitAsync(UpdateInfo info)
    {
        if (Environment.ProcessPath is not { } exe) return;
        try
        {
            ToastService.Shared.Show("Downloading the update…", "It installs when you quit", "download", "ok", null, 30);
            _stagedForQuit = await AppUpdater.StageAsync(info, exe);
            ToastService.Shared.Show($"OMNIServers {info.Latest} is ready", "It installs when you quit", "download", "ok", null, 6);
        }
        catch (Exception e) { ToastService.Shared.Error("Couldn't download the update: " + e.Message); }
    }

    /// <summary>Called as the app exits: puts a staged update in place so the next start is the new version.</summary>
    public static void ApplyOnQuit()
    {
        if (_stagedForQuit is not { } staged || Environment.ProcessPath is not { } exe || !File.Exists(staged)) return;
        try { AppUpdater.Swap(exe, staged); } catch { /* the staged file stays; nothing is half-replaced */ }
        _stagedForQuit = null;
    }

    /// <summary>
    /// Makes sure OMNI Launcher is installed before something opens it. Not installed: asks, then downloads the latest build from GitHub and installs it.
    /// Installed by this app and a newer build exists: offers the update once per run. Returns true when a launcher is ready to open.
    /// </summary>
    public static async Task<bool> EnsureLauncherAsync()
    {
        var installed = OmniLauncherLink.InstalledPath();
        if (installed is null && !OmniLauncherLink.IsRunning())
        {
            if (_launcherDeclined) return false;
            if (LauncherInstaller.Platform() is null) { await Dialogs.Current.ShowMessageAsync("OMNI Launcher isn't available here yet", "There's no OMNI Launcher build for this computer yet."); return false; }
            if (!await Dialogs.Current.ConfirmAsync("OMNI Launcher isn't installed", "OMNI Launcher is the Minecraft launcher that goes with OMNIServers. Download the latest version from GitHub and install it for you?", "Download and install"))
            { _launcherDeclined = true; return false; }
            return await InstallLauncherAsync(update: false);
        }
        if (installed is not null && !_launcherAsked && !OmniLauncherLink.IsRunning())
        {
            _launcherAsked = true;
            try
            {
                var latest = await LauncherInstaller.LatestAsync();
                if (LauncherInstaller.IsUpdateAvailable(LauncherInstaller.InstalledTag(), latest.Tag)
                    && await Dialogs.Current.ConfirmAsync("A newer OMNI Launcher is available", $"Update OMNI Launcher to {latest.Tag.Replace("omni-launcher-", "")} now?", "Update"))
                    await InstallLauncherAsync(update: true);
            }
            catch { /* offline: just open the one that's installed */ }
        }
        return true;
    }

    static async Task<bool> InstallLauncherAsync(bool update)
    {
        try
        {
            ToastService.Shared.Show(update ? "Updating OMNI Launcher…" : "Downloading OMNI Launcher…", "This takes a moment", "download", "ok", null, 120);
            var rel = await LauncherInstaller.LatestAsync();
            await LauncherInstaller.InstallAsync(rel);
            ToastService.Shared.Show(update ? "OMNI Launcher updated" : "OMNI Launcher installed", rel.Tag.Replace("omni-launcher-", ""), "check", "ok", null, 4);
            return true;
        }
        catch (Exception e)
        {
            await Dialogs.Current.ShowMessageAsync("Couldn't install OMNI Launcher", e.Message);
            return false;
        }
    }
}
