using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace CraftPanel.Core.Security;

/// <summary>An app PIN (Argon2id), stored in lock.json.</summary>
public sealed class AppLock
{
    readonly string _file;
    public AppLock(string? file = null) => _file = file ?? Path.Combine(AppPaths.DataDir, "lock.json");

    public bool IsSet => File.Exists(_file);

    public void Set(string pin)
    {
        if (pin.Length < 4) throw new ProvisionException("Use at least 4 characters.");
        AppPaths.WriteAtomic(_file, JsonSerializer.Serialize(new { phc = Argon2.Encode(pin) }));
    }

    public bool Verify(string pin)
    {
        try { return Argon2.Verify(pin, JsonNode.Parse(File.ReadAllText(_file))!["phc"]!.GetValue<string>()); } catch { return false; }
    }

    public void Clear() { try { File.Delete(_file); } catch { } }
}
