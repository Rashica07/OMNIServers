namespace CraftPanel.Core.Runtime;

/// <summary>
/// Recognises the handful of ways a server fails to start for reasons that aren't the server's fault (missing files, a
/// network that blocks downloads) and says what to do in plain words, right in the console.
/// </summary>
public static class StartupAdvice
{
    public static string MissingLaunchFile(string file) =>
        $"The server's launch file ({file}) isn't in the server folder, so it can't start. It may have been deleted, or this PC clears its folders (some school and work PCs do). Open the ⋯ menu → Change version…, pick the same version and press Switch version to download it again — your world and mods stay.";

    /// <summary>Advice for one console line, or null if the line is nothing special.</summary>
    public static string? Classify(string line)
    {
        if (string.IsNullOrWhiteSpace(line)) return null;
        var l = line;
        if (l.Contains("Unable to access jarfile", StringComparison.OrdinalIgnoreCase))
            return "Java can't find the server's launch file. Open the ⋯ menu → Change version…, pick the same version and press Switch version to download it again — your world and mods stay.";
        if ((l.Contains("fabric-loader", StringComparison.OrdinalIgnoreCase) || l.Contains("net.fabricmc", StringComparison.OrdinalIgnoreCase))
            && (l.Contains("NoSuchFileException", StringComparison.OrdinalIgnoreCase) || l.Contains("FileNotFoundException", StringComparison.OrdinalIgnoreCase)
                || l.Contains("does not exist", StringComparison.OrdinalIgnoreCase) || l.Contains("not found", StringComparison.OrdinalIgnoreCase) || l.Contains("ClassNotFoundException", StringComparison.OrdinalIgnoreCase)))
            return "Fabric's own files are missing or incomplete (the .fabric and libraries folders). Close the server, delete the .fabric folder inside the server folder, and start it again while connected to a network that allows downloads — Fabric rebuilds it. Or use ⋯ → Change version… with the same version.";
        if (l.Contains("Could not find or load main class net.fabricmc", StringComparison.OrdinalIgnoreCase))
            return "Fabric's launcher is damaged or incomplete. Use ⋯ → Change version… with the same version to download it again.";
        if (l.Contains("UnknownHostException", StringComparison.OrdinalIgnoreCase) || l.Contains("SSLHandshakeException", StringComparison.OrdinalIgnoreCase)
            || (l.Contains("timed out", StringComparison.OrdinalIgnoreCase) && (l.Contains("connect", StringComparison.OrdinalIgnoreCase) || l.Contains("download", StringComparison.OrdinalIgnoreCase)))
            || l.Contains("Failed to download", StringComparison.OrdinalIgnoreCase) || l.Contains("Could not download", StringComparison.OrdinalIgnoreCase))
            return "The server needs to download files (Minecraft and loader libraries) and couldn't reach them. A school or work network often blocks maven.fabricmc.net, piston-data.mojang.com and libraries.minecraft.net. Try once on a network that allows it (the files are kept afterwards), or ask IT to allow those sites. Settings → Diagnostics shows which are blocked.";
        return null;
    }
}
