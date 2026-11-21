using System.Text.Json.Serialization;

namespace CraftPanel.Core;

/// <summary>A saved server — what OMNIServers remembers about a server between launches.</summary>
public sealed class ServerRecord
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string Path { get; set; } = "";
    public ServerType ServerType { get; set; } = ServerType.Vanilla;
    public string LaunchTarget { get; set; } = "";
    public string? McVersion { get; set; }
    /// <summary>Absolute path, or bare <c>java</c> to pick one automatically at start.</summary>
    public string JavaPath { get; set; } = "java";
    public uint RamMB { get; set; } = 4096;
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
    public string? JvmArgs { get; set; }
    public string? ManualTunnelAddress { get; set; }
    public ScheduleConfig Schedule { get; set; } = new();

    [JsonIgnore] public string Dir => Path;
}

/// <summary>Per-server automation.</summary>
public sealed class ScheduleConfig
{
    public bool RestartOnCrash { get; set; }
    public int MaxCrashRestarts { get; set; } = 3;
    /// <summary>Local time "HH:mm" for a daily restart, or null.</summary>
    public string? DailyRestart { get; set; }
    public bool BackupOnStop { get; set; }
    /// <summary>Commands sent once each time the server finishes starting.</summary>
    public List<string> OnStartCommands { get; set; } = [];
    public bool AutoStartWithApp { get; set; }
    /// <summary>Minutes between automatic Time Machine snapshots while the server runs, or null for off.</summary>
    public int? SnapshotIntervalMins { get; set; }
    /// <summary>Keep every snapshot from this many hours (0 = the default, 24).</summary>
    public int SnapshotKeepRecentHours { get; set; }
    /// <summary>Then thin to one a day for this many days (0 = the default, 30).</summary>
    public int SnapshotKeepDailyDays { get; set; }
    [JsonIgnore] public int SnapshotRecentHours => SnapshotKeepRecentHours == 0 ? 24 : SnapshotKeepRecentHours;
    [JsonIgnore] public int SnapshotDailyDays => SnapshotKeepDailyDays == 0 ? 30 : SnapshotKeepDailyDays;
}
