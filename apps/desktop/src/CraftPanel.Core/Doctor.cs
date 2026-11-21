using CraftPanel.Core.Java;
using CraftPanel.Core.Network;

namespace CraftPanel.Core;

public enum CheckLevel { Ok, Warn, Bad }

public sealed record DoctorCheck(string Name, CheckLevel Level, string Detail);

/// <summary>A quick health check: Java, disk, ports, network, firewall.</summary>
public static class Doctor
{
    public static async Task<List<DoctorCheck>> RunAsync(string serversDir, CancellationToken ct = default)
    {
        var list = new List<DoctorCheck>();

        // Where OMNIServers keeps its files, and whether that actually works on this PC (school and work PCs often lock folders).
        list.Add(AppPaths.CanWrite(AppPaths.DataDir)
            ? new("Saving files", AppPaths.Mode == DataMode.Normal ? CheckLevel.Ok : CheckLevel.Warn, AppPaths.ModeNote)
            : new("Saving files", CheckLevel.Bad, $"CraftPanel can't write to {AppPaths.DataDir}. Put a file called {AppPaths.PortableMarker} next to CraftPanel.exe (on a USB stick or a folder you own) and start it again."));
        if (OperatingSystem.IsWindows())
        {
            var ps = await Proc.RunAsync("powershell", ["-NoProfile", "-NonInteractive", "-Command", "exit 0"], timeout: TimeSpan.FromSeconds(10), ct: ct);
            list.Add(ps is { Success: true } ? new("PowerShell", CheckLevel.Ok, "Available (used for the firewall button and memory details).")
                : new("PowerShell", CheckLevel.Warn, "Blocked or missing on this PC. Everything still works, but the 'Allow through Windows Firewall' button and memory details won't. If friends can't join, ask whoever manages this PC to allow the Minecraft port."));
            try
            {
                using var id = System.Security.Principal.WindowsIdentity.GetCurrent();
                var admin = new System.Security.Principal.WindowsPrincipal(id).IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
                list.Add(admin ? new("Administrator", CheckLevel.Ok, "Running as administrator.")
                    : new("Administrator", CheckLevel.Ok, "Normal user account — fine. Opening a firewall port asks for an administrator's password; on a school PC ask IT to allow the Minecraft port (default 25565)."));
            }
            catch { }
        }

        var runtimes = await JavaProbe.ListRuntimesAsync(ct);
        list.Add(runtimes.Count == 0
            ? new("Java", CheckLevel.Warn, "No Java found. OMNIServers installs one automatically when you create or start a server — or install one in Settings → Java.")
            : new("Java", CheckLevel.Ok, "Found " + string.Join(", ", runtimes.Select(r => $"Java {r.Major}"))));

        try
        {
            Directory.CreateDirectory(serversDir);
            var free = new DriveInfo(Path.GetPathRoot(Path.GetFullPath(serversDir))!).AvailableFreeSpace / 1_073_741_824;
            list.Add(free < 5 ? new("Disk space", CheckLevel.Bad, $"Only {free} GB free where servers are stored.")
                : free < 20 ? new("Disk space", CheckLevel.Warn, $"{free} GB free — worlds and backups add up.")
                : new("Disk space", CheckLevel.Ok, $"{free} GB free"));
        }
        catch (Exception e) { list.Add(new("Servers folder", CheckLevel.Bad, "Can't use " + serversDir + ": " + e.Message)); }

        list.Add(Net.PortFree(25565) ? new("Port 25565", CheckLevel.Ok, "Free — the default Minecraft port is available.")
            : new("Port 25565", CheckLevel.Warn, "In use right now (a server may be running). New servers pick a free port automatically."));

        list.Add(Net.LanIp() is { } ip ? new("Network", CheckLevel.Ok, $"This PC is {ip} on your network.") : new("Network", CheckLevel.Warn, "No network connection found — friends won't be able to join."));

        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct); cts.CancelAfter(TimeSpan.FromSeconds(6));
            using var r = await Http.Client.SendAsync(new HttpRequestMessage(HttpMethod.Head, "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"), cts.Token);
            list.Add(r.IsSuccessStatusCode ? new("Mojang downloads", CheckLevel.Ok, "Reachable") : new("Mojang downloads", CheckLevel.Warn, $"Answered HTTP {(int)r.StatusCode}"));
        }
        catch { list.Add(new("Mojang downloads", CheckLevel.Bad, "Couldn't reach Mojang's servers — creating servers needs internet.")); }

        // Servers download Minecraft, loaders and libraries from these sites; school and work networks often block some of them.
        var hosts = new[] { "meta.fabricmc.net", "maven.fabricmc.net", "piston-data.mojang.com", "libraries.minecraft.net", "api.papermc.io", "api.modrinth.com" };
        var results = await Task.WhenAll(hosts.Select(async h =>
        {
            try
            {
                using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct); cts.CancelAfter(TimeSpan.FromSeconds(6));
                using var r = await Http.Client.SendAsync(new HttpRequestMessage(HttpMethod.Head, "https://" + h + "/"), cts.Token);
                return (h, ok: true);     // any answer, even 404, means the site is reachable
            }
            catch { return (h, ok: false); }
        }));
        var blocked = results.Where(r => !r.ok).Select(r => r.h).ToList();
        list.Add(blocked.Count == 0 ? new("Download access", CheckLevel.Ok, "The sites servers download from are reachable.")
            : new("Download access", CheckLevel.Warn, $"Can't reach: {string.Join(", ", blocked)}. Creating or starting some servers (Fabric especially) needs these. On a school or work network ask IT to allow them, or try another network once."));

        if (Firewall.Supported)
        {
            var any = await Firewall.RuleExistsAsync("CraftPanel - *");
            list.Add(new("Windows Firewall", CheckLevel.Ok, "Manage per-server rules in each server's Network tab."));
        }
        return list;
    }
}
