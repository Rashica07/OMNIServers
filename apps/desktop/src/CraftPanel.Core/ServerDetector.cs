using CraftPanel.Core.Adapters;
using CraftPanel.Core.Java;

namespace CraftPanel.Core;

public sealed record DetectionResult(string Path, bool Detected, ServerType? ServerType, string? LaunchTarget, string? McVersion,
    IReadOnlyList<string> Evidence, JavaInfo? Java, IReadOnlyList<string> Warnings);

/// <summary>What the "Add existing server" flow calls: Minecraft first, then Bedrock, else a clear "nothing here" result (never an exception).</summary>
public static class ServerDetector
{
    public static async Task<DetectionResult> DetectAsync(string path, string? javaExecutable = null, CancellationToken ct = default)
    {
        if (!Directory.Exists(path)) return new(path, false, null, null, null, [], null, ["That path is not a folder."]);

        var warnings = new List<string>();
        var mc = MinecraftAdapter.Inspect(path);
        if (mc is not null)
        {
            var java = await JavaProbe.ProbeAsync(javaExecutable, ct);
            if (java is null) warnings.Add("No Java runtime was found on this PC — OMNIServers will offer to install one before the server starts.");
            else if (JavaProbe.CompatibilityWarning(java, mc.McVersion) is { } w) warnings.Add(w);
            if (mc.McVersion is null) warnings.Add("Couldn't determine the Minecraft version automatically — set it in the server's settings if Java looks mismatched.");
            return new(path, true, mc.ServerType, mc.LaunchTarget, mc.McVersion, mc.Evidence, java, warnings);
        }
        if (Adapters.OmniHostAdapter.IsServerFolder(path))
        {
            var engine = Adapters.PumpkinEngine.InstalledBinary() ?? "pumpkin";   // OMNIHost needs no Java
            return new(path, true, ServerType.OmniHost, engine, Adapters.PumpkinEngine.MinecraftVersion, [Adapters.PumpkinConfig.FileName], null, []);
        }

        if (BedrockAdapter.Inspect(path) is { } bedrock)
            return new(path, true, ServerType.Bedrock, bedrock, null, [bedrock], null, []);   // Bedrock needs no Java

        if (GameServers.Inspect(path) is { } game)
        {
            if (!GameServers.IsPlatformSupported(game.Type)) warnings.Add($"{game.Type.Label()} has no server for this operating system, so it can be added but not started here.");
            warnings.Add("OMNIServers will repair the setup (config file, ports) when you add it.");
            return new(path, true, game.Type, game.LaunchTarget, null, [game.Evidence], null, warnings);
        }

        warnings.Add("No Minecraft, FiveM or Terraria server detected here. Expected something like fabric-server-launch.jar, a Forge run script, paper.jar, spigot.jar, server.jar, or bedrock_server.exe.");
        return new(path, false, null, null, null, [], null, warnings);
    }
}
