using System.Text.Json;

namespace CraftPanel.Core;

/// <summary>App-level preferences (settings.json). Every setter saves immediately.</summary>
public sealed class AppSettings
{
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    string _file = AppPaths.SettingsJson;

    public event Action? Changed;

    public uint DefaultRamMB { get; set; } = 4096;
    public string DefaultJava { get; set; } = "java";
    public bool KeepServersOnQuit { get; set; }
    public bool NotifyJoins { get; set; } = true;
    public bool NotifyChat { get; set; }
    public string ChatName { get; set; } = "Host";
    public string Theme { get; set; } = "dark";
    public bool ExpertMode { get; set; }
    public int BackupKeep { get; set; } = 10;
    public bool BackupTiered { get; set; }
    public bool StayAwake { get; set; }
    /// <summary>Keep the server running when the laptop lid is closed.</summary>
    public bool KeepRunningLidClosed { get; set; }
    /// <summary>The lid-close actions Windows had before we changed them (so we can put them back).</summary>
    public int? LidSavedAc { get; set; }
    public int? LidSavedDc { get; set; }
    public string InstallId { get; set; } = "";
    public string? WindowState { get; set; }
    /// <summary>The first-launch tour has been shown (or skipped); it can always be reopened from Help.</summary>
    public bool HelpTourDone { get; set; }
    /// <summary>"auto" (default), "on" or "off": see <c>LightMode</c>.</summary>
    /// <summary>Look for a newer version when OMNIServers opens.</summary>
    public bool AutoCheckUpdates { get; set; } = true;
    /// <summary>The sidebar is shrunk to a rail of large icons.</summary>
    public bool SidebarCollapsed { get; set; }
    public string LightMode { get; set; } = "auto";

    public static AppSettings Load(string? file = null)
    {
        file ??= AppPaths.SettingsJson;
        AppSettings s;
        try { s = File.Exists(file) ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(file), Json) ?? new() : new(); }
        catch { s = new(); }
        s._file = file;
        if (s.InstallId.Length == 0) { s.InstallId = Guid.NewGuid().ToString("N")[..16]; s.Save(); }
        return s;
    }

    public void Save()
    {
        AppPaths.WriteAtomic(_file, JsonSerializer.Serialize(this, Json));
        Changed?.Invoke();
    }

    [System.Text.Json.Serialization.JsonIgnore]
    public string EffectiveChatName => string.IsNullOrWhiteSpace(ChatName) ? "Host" : ChatName.Trim()[..Math.Min(32, ChatName.Trim().Length)];
}
