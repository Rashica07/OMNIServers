using System.Text.Json.Serialization;

namespace CraftPanel.Core;

[JsonConverter(typeof(JsonStringEnumConverter<ServerType>))]
public enum ServerType { Vanilla, Paper, Spigot, Fabric, Forge, NeoForge, Bedrock, FiveM, Terraria, OmniHost }

public static class ServerTypeExt
{
    public static string Label(this ServerType t) => t switch
    {
        ServerType.NeoForge => "NeoForge",
        ServerType.FiveM => "FiveM",
        ServerType.OmniHost => "OMNIHost",
        _ => t.ToString(),
    };
    /// <summary>A non-Minecraft game server: its own program, its own config file, no Java, no RCON.</summary>
    public static bool IsGame(this ServerType t) => t is ServerType.FiveM or ServerType.Terraria;
    /// <summary>Runs on Java (every Minecraft Java flavour except native OMNIHost).</summary>
    public static bool UsesJava(this ServerType t) => t is not (ServerType.Bedrock or ServerType.FiveM or ServerType.Terraria or ServerType.OmniHost);
    public static bool IsBedrock(this ServerType t) => t == ServerType.Bedrock;
    public static bool IsOmniHost(this ServerType t) => t == ServerType.OmniHost;
    public static bool IsForgeFamily(this ServerType t) => t is ServerType.Forge or ServerType.NeoForge;
    public static bool UsesModsFolder(this ServerType t) => t is ServerType.Fabric or ServerType.Forge or ServerType.NeoForge;
    /// <summary>Paper/Spigot load plugins; Fabric/Forge/NeoForge load mods; Vanilla loads neither.</summary>
    public static bool UsesPlugins(this ServerType t) => t is ServerType.Paper or ServerType.Spigot;
    public static bool CanRunAddons(this ServerType t) => t is not (ServerType.Vanilla or ServerType.Bedrock or ServerType.FiveM or ServerType.Terraria or ServerType.OmniHost);
}
