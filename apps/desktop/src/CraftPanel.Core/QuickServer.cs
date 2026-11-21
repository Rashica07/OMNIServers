namespace CraftPanel.Core;

/// <summary>One click: the newest stable vanilla Minecraft, with memory sized for this PC.</summary>
public sealed record QuickPlan(string McVersion, int RamMB, string Name, string Dir);

public static class QuickServer
{
    public const int Players = 5;

    /// <summary>The newest release in <paramref name="versions"/> (Mojang lists newest first; snapshots are skipped).</summary>
    public static string? PickVersion(IEnumerable<VersionInfo> versions) =>
        versions.FirstOrDefault(v => v.Kind == "release")?.Id;

    /// <summary>First free "My Server", "My Server 2"… and a folder that does not exist yet.</summary>
    public static (string Name, string Dir) PickName(string baseDir, IEnumerable<string> usedNames)
    {
        var used = usedNames.ToHashSet(StringComparer.OrdinalIgnoreCase);
        for (var i = 1; ; i++)
        {
            var name = i == 1 ? "My Server" : $"My Server {i}";
            var dir = Path.Combine(baseDir, name.Replace(' ', '-'));
            if (!used.Contains(name) && !(Directory.Exists(dir) && Directory.EnumerateFileSystemEntries(dir).Any())) return (name, dir);
        }
    }

    public static QuickPlan? Plan(IEnumerable<VersionInfo> versions, SystemMemory sys, string baseDir, IEnumerable<string> usedNames)
    {
        if (PickVersion(versions) is not { } mc) return null;
        var (name, dir) = PickName(baseDir, usedNames);
        return new QuickPlan(mc, RamAdvisor.Recommend(RamKind.VanillaLike, Players, sys.SafeMaxMB), name, dir);
    }

    public static async Task<(ServerRecord Record, Created Created)> CreateAsync(ServerStore store, string javaDefault, string baseDir,
        IProgress<ProvisionProgress>? progress, CancellationToken ct = default)
    {
        progress?.Report(new("fetch", "Finding the latest Minecraft…"));
        var versions = await Provisioner.ListVersionsAsync(Loader.Vanilla, ct);
        var plan = Plan(versions, SystemMemory.Current(), baseDir, store.All.Select(s => s.Name))
            ?? throw new ProvisionException("Couldn't find a Minecraft release to install.");
        var created = await Provisioner.CreateAsync(new CreateSpec(Loader.Vanilla, plan.McVersion, null, plan.Dir, plan.Name, (uint)plan.RamMB, javaDefault), progress, ct);
        Provisioner.ApplyStartingSettings(plan.Dir, false, Provisioner.PickFreePort(store.TakenPorts()), null, null, null, null, null);
        var rec = new ServerRecord
        {
            Name = plan.Name, Path = plan.Dir, ServerType = created.ServerType, LaunchTarget = created.LaunchTarget, McVersion = created.McVersion,
            JavaPath = created.JavaPath, RamMB = (uint)plan.RamMB,
        };
        store.Add(rec);
        return (rec, created);
    }
}
