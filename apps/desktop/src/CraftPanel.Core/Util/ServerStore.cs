using System.Text.Json;

namespace CraftPanel.Core;

/// <summary>The saved server list (servers.json). Thread-safe; raises <see cref="Changed"/> after every write.</summary>
public sealed class ServerStore
{
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    readonly object _gate = new();
    readonly string _file;
    List<ServerRecord> _servers = [];

    public event Action? Changed;

    public ServerStore(string? file = null)
    {
        _file = file ?? AppPaths.ServersJson;
        Load();
    }

    public IReadOnlyList<ServerRecord> All { get { lock (_gate) return _servers.ToList(); } }
    public ServerRecord? Find(Guid id) { lock (_gate) return _servers.FirstOrDefault(s => s.Id == id); }

    void Load()
    {
        try
        {
            if (!File.Exists(_file)) return;
            _servers = JsonSerializer.Deserialize<List<ServerRecord>>(File.ReadAllText(_file), Json) ?? [];
        }
        catch
        {
            // Unreadable list: keep it aside instead of losing it, start empty. Server folders are untouched.
            try { File.Move(_file, _file + ".broken-" + DateTimeOffset.UtcNow.ToUnixTimeSeconds(), overwrite: true); } catch { }
            _servers = [];
        }
    }

    void Save()
    {
        AppPaths.WriteAtomic(_file, JsonSerializer.Serialize(_servers, Json));
        Changed?.Invoke();
    }

    public void Add(ServerRecord r) { lock (_gate) { _servers.Add(r); Save(); } }
    public void Update(ServerRecord r) { lock (_gate) { Save(); } }
    public void Remove(Guid id) { lock (_gate) { _servers.RemoveAll(s => s.Id == id); Save(); } }

    /// <summary>Ports already used by known servers (server.properties), for picking a free one.</summary>
    public HashSet<int> TakenPorts() => All.Select(s => Properties.Load(s.Path).GetInt("server-port", 25565)).ToHashSet();
}
