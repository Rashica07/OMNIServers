using CraftPanel.Core;

namespace CraftPanel.Core.Performance;

public sealed record PresetChange(string Key, string? From, string To, string Why);

/// <summary>
/// Settings that make a server easier on a small PC: fewer chunks sent to each player and simulated around them.
/// It only ever lowers a value (never raises one you already made smaller), and shows what it would change first.
/// </summary>
public static class LowSpecPreset
{
    /// <summary>What would change for this server, given what's in its server.properties right now.</summary>
    public static List<PresetChange> Plan(Properties p, ServerType type)
    {
        var plan = new List<PresetChange>();
        void Lower(string key, int target, int assumedDefault, string why)
        {
            var current = p.GetInt(key, assumedDefault);
            if (current > target) plan.Add(new PresetChange(key, p.Get(key), target.ToString(), why));
        }
        if (type.IsBedrock())
        {
            Lower("view-distance", 8, 32, "Fewer chunks drawn around each player");
            Lower("tick-distance", 4, 4, "Less of the world kept active");
        }
        else
        {
            Lower("view-distance", 6, 10, "Fewer chunks sent to each player");
            Lower("simulation-distance", 4, 10, "Fewer chunks where mobs and crops are updated");
        }
        return plan;
    }

    public static void Apply(Properties p, IEnumerable<PresetChange> changes)
    {
        foreach (var c in changes) p.Set(c.Key, c.To);
        p.Save();
    }
}
