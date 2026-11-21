using System.Text.Json;
using System.Text.Json.Serialization;
using CraftPanel.Cluster.Discovery;
using CraftPanel.Core;

namespace CraftPanel.Cluster.Identity;

/// <summary>What this PC remembers about its place in a cluster. Off by default: nothing is advertised until the user opts in.</summary>
public sealed class ClusterSettings
{
    [JsonPropertyName("instanceId")] public string InstanceId { get; set; } = "";
    [JsonPropertyName("role")] [JsonConverter(typeof(JsonStringEnumConverter<ClusterRole>))] public ClusterRole Role { get; set; } = ClusterRole.Off;
    [JsonPropertyName("agentPort")] public int AgentPort { get; set; } = DefaultAgentPort;

    public const int DefaultAgentPort = 47900;

    /// <summary>A random id, generated once per install, that tells this PC apart from its peers (never derived from hardware).</summary>
    public static string NewId() => Guid.NewGuid().ToString("N");
}

public sealed class ClusterSettingsStore(string? file = null)
{
    readonly string _file = file ?? Path.Combine(AppPaths.DataDir, "cluster.json");
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public ClusterSettings Load()
    {
        ClusterSettings? s = null;
        try { s = JsonSerializer.Deserialize<ClusterSettings>(File.ReadAllText(_file), Json); } catch { }
        s ??= new ClusterSettings();
        var dirty = false;
        if (s.InstanceId.Length < 8 || s.InstanceId.Any(c => !Uri.IsHexDigit(c) || char.IsUpper(c))) { s.InstanceId = ClusterSettings.NewId(); dirty = true; }
        if (s.AgentPort is < 1024 or > 65535) { s.AgentPort = ClusterSettings.DefaultAgentPort; dirty = true; }
        if (dirty) Save(s);
        return s;
    }

    public void Save(ClusterSettings s) => AppPaths.WriteAtomic(_file, JsonSerializer.Serialize(s, Json));
}
