namespace CraftPanel.Core;

/// <summary>One thing a server log says is wrong, with plain advice.</summary>
public sealed record LogFinding(string Id, bool IsError, string Title, string Advice);

/// <summary>Reads a server log and says what looks wrong and what to do. Text in, findings out.</summary>
public static class LogAnalyzer
{
    sealed record Rule(string Id, bool Error, string[] Patterns, string Title, string Advice);

    static readonly Rule[] Rules =
    [
        new("eula", true, ["you need to agree to the eula", "eula.txt"], "The Minecraft EULA isn't accepted", "Start the server from OMNIServers once and accept the EULA, or set eula=true in eula.txt."),
        new("port", true, ["address already in use", "failed to bind to port", "perhaps a server is already running"], "The port is already taken", "Another server or app is using this port. Stop it, or change the server port in Network."),
        new("java-version", true, ["unsupportedclassversionerror", "has been compiled by a more recent version of the java runtime"], "This server needs a newer Java", "Pick a newer Java in the server's launch settings (Minecraft 1.20.5 and up needs Java 21)."),
        new("oom", true, ["java.lang.outofmemoryerror", "could not reserve enough space"], "The server ran out of memory", "Give it more memory in Settings, or remove heavy mods. Keep some memory free for your computer."),
        new("dependency", true, ["missing or unsupported mandatory dependencies", "requires mod", "missing mandatory dependencies", "could not find required mod"], "A mod is missing something it needs", "Open Mods and add the library mod it names (often Fabric API or a matching Forge version)."),
        new("duplicate-mod", true, ["duplicate mod", "duplicate mods", "found duplicate"], "The same mod is installed twice", "Open Mods and delete one copy of the mod it names."),
        new("mixin", true, ["mixin apply failed", "mixintransformererror", "invalidmixinexception"], "Two mods clash", "Turn off the most recently added mod in Mods, then start again. Update both if you can."),
        new("world", true, ["failed to load level", "failed to read level.dat", "world is corrupted"], "The world won't load", "Restore a backup from Backups. A world saved by a newer Minecraft version can't load on an older server."),
        new("cant-keep-up", false, ["can't keep up!"], "The server is lagging", "Lower view distance, give it more memory, or switch to Paper."),
        new("plugin-error", false, ["could not load 'plugins/", "error occurred while enabling"], "A plugin failed to load", "Open Mods & plugins and update or remove the plugin named in the log."),
        new("offline", false, ["failed to verify username", "authentication servers are down"], "Players can't sign in", "Mojang's sign-in may be down, or the player's account isn't verified. Try again in a few minutes."),
    ];

    public static IReadOnlyList<LogFinding> Analyze(string log)
    {
        var lower = (log ?? "").ToLowerInvariant();
        return Rules.Where(r => r.Patterns.Any(lower.Contains)).Select(r => new LogFinding(r.Id, r.Error, r.Title, r.Advice)).ToList();
    }
}
