using System.Diagnostics;

namespace CraftPanel.Core.Network;

/// <summary>What the "Join" button does. Bedrock has a link that adds the server and opens the game; Java has no such link in the official launcher.</summary>
public sealed record JoinPlan(bool Bedrock, string? Uri, string Address, string Name);

public static class JoinLink
{
    public static JoinPlan Plan(ServerType type, string serverName, string address) =>
        type.IsBedrock()
            ? new JoinPlan(true, $"minecraft://?addExternalServer={Uri.EscapeDataString(serverName)}|{address}", address, serverName)
            : new JoinPlan(false, null, address, serverName);

    /// <summary>Where the official Java launcher usually lives on this OS (first that exists wins).</summary>
    public static IEnumerable<string> JavaLauncherCandidates()
    {
        if (OperatingSystem.IsWindows())
        {
            var pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
            var pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            yield return Path.Combine(pf86, "Minecraft Launcher", "MinecraftLauncher.exe");
            yield return Path.Combine(pf, "Minecraft Launcher", "MinecraftLauncher.exe");
        }
        else if (OperatingSystem.IsMacOS())
        {
            yield return "/Applications/Minecraft.app";
        }
        else
        {
            yield return "/usr/bin/minecraft-launcher";
            yield return "/opt/minecraft-launcher/minecraft-launcher";
        }
    }

    /// <summary>Opens the game for this plan. Returns true if something was opened.</summary>
    public static bool Open(JoinPlan plan)
    {
        try
        {
            if (plan.Uri is { } uri)
            {
                if (OperatingSystem.IsMacOS()) Process.Start("open", [uri]);
                else if (OperatingSystem.IsLinux()) Process.Start("xdg-open", [uri]);
                else Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true });
                return true;
            }
            var launcher = JavaLauncherCandidates().FirstOrDefault(p => File.Exists(p) || Directory.Exists(p));
            if (launcher is null) return false;
            if (OperatingSystem.IsMacOS()) Process.Start("open", [launcher]);
            else Process.Start(new ProcessStartInfo(launcher) { UseShellExecute = true });
            return true;
        }
        catch { return false; }
    }
}
