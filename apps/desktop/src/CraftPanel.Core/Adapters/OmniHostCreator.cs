namespace CraftPanel.Core.Adapters;

/// <summary>"New OMNIHost server": downloads the engine on first use, makes the folder and writes <c>pumpkin.toml</c> from the wizard's choices.</summary>
public static class OmniHostCreator
{
    public static async Task<Created> CreateAsync(string dir, PumpkinConfig.Settings settings, IProgress<ProvisionProgress>? progress = null, CancellationToken ct = default)
    {
        Directory.CreateDirectory(dir);
        if (Directory.EnumerateFileSystemEntries(dir).Any()) throw new ProvisionException("That folder isn't empty — pick a fresh folder for a new server.");
        var engine = await PumpkinEngine.EnsureInstalledAsync(progress, ct);
        progress?.Report(new("fix", "Setting it up", null));
        File.WriteAllText(Path.Combine(dir, PumpkinConfig.FileName), PumpkinConfig.Render(settings));
        OmniHostAdapter.InstallIcon(dir);
        return new(ServerType.OmniHost, engine, PumpkinEngine.MinecraftVersion, dir, "");
    }
}
