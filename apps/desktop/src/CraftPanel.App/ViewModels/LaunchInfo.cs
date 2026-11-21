using CraftPanel.Core.Adapters;

namespace CraftPanel.App.ViewModels;

/// <summary>One line of the launch checklist shown under the server name while it starts.</summary>
public sealed record LaunchStep(string Label, bool Done, bool Active)
{
    public string Mark => Done ? "✓" : Active ? "•" : "";
    public double Opacity => Done || Active ? 1 : 0.5;
}

/// <summary>Pure helpers for the header: the address chip, the invite text and the launch checklist.</summary>
public static class LaunchInfo
{
    public static string Address(string? lanIp, int port) => lanIp is { Length: > 0 } ip ? $"{ip}:{port}" : $"localhost:{port}";

    public static string InviteText(string name, string address, string? version) =>
        $"Join my Minecraft server \"{name}\"!\nAddress: {address}\n" + (string.IsNullOrEmpty(version) ? "" : $"Game: Minecraft {version}\n") +
        "In Minecraft: Multiplayer → Add Server → paste the address.";

    /// <summary>Three honest steps taken from the real server state: the checklist only moves when the server does.</summary>
    public static IReadOnlyList<LaunchStep> Steps(ServerStatus status) => status switch
    {
        ServerStatus.Starting => [new("Java ready", true, false), new("Loading the world", false, true), new("Ready for players", false, false)],
        ServerStatus.Running => [new("Java ready", true, false), new("World loaded", true, false), new("Ready for players", true, false)],
        _ => [],
    };
}
