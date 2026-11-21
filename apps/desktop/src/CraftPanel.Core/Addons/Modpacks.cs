using System.IO.Compression;
using System.Text.Json.Nodes;
using CraftPanel.Core.Adapters;
using CraftPanel.Core.Java;

namespace CraftPanel.Core.Addons;

public sealed record ModpackHit(string ProjectId, string Title, string Description, string? IconUrl, int Downloads);

/// <summary>Modrinth modpacks (.mrpack): loader install, checksum-verified mod downloads from allow-listed hosts, symlink-safe override merging.</summary>
public static class Modpacks
{
    public static readonly HashSet<string> AllowedHosts = ["cdn.modrinth.com", "github.com", "raw.githubusercontent.com", "gitlab.com"];

    public static async Task<List<ModpackHit>> SearchAsync(string query, CancellationToken ct = default)
    {
        var url = $"https://api.modrinth.com/v2/search?query={Uri.EscapeDataString(query)}&facets={Uri.EscapeDataString("[[\"project_type:modpack\"]]")}&limit=20&index={(query.Length == 0 ? "downloads" : "relevance")}";
        var j = await Http.GetJsonAsync(url, ct);
        return j["hits"]!.AsArray().Select(h => new ModpackHit(h!["project_id"]!.GetValue<string>(), h["title"]!.GetValue<string>(), h["description"]?.GetValue<string>() ?? "",
            h["icon_url"]?.GetValue<string>(), h["downloads"]?.GetValue<int>() ?? 0)).ToList();
    }

    public static bool SafeRelativePath(string p)
    {
        if (p.Length == 0 || p.StartsWith('/') || p.Contains('\0') || p.Contains('\\')) return false;
        var comps = p.Split('/');
        return !comps.Contains("..") && !comps.Contains("");
    }

    public static Uri? DownloadAllowed(string s) =>
        Uri.TryCreate(s, UriKind.Absolute, out var u) && u.Scheme == "https" && AllowedHosts.Contains(u.Host) ? u : null;

    public static async Task<Created> CreateAsync(string projectId, string dir, string name, uint ramMB, string? javaPath, ISet<int> takenPorts,
        IProgress<ProvisionProgress>? progress = null, CancellationToken ct = default)
    {
        Directory.CreateDirectory(dir);
        if (Directory.EnumerateFileSystemEntries(dir).Any()) throw new ProvisionException("That folder isn't empty — pick a fresh folder for a new server.");
        var java = string.IsNullOrEmpty(javaPath) ? "java" : javaPath;

        progress?.Report(new("fetch", "Looking up the modpack…", null));
        var versions = (await Http.GetJsonAsync($"https://api.modrinth.com/v2/project/{projectId}/version", ct)).AsArray();
        var version = versions.FirstOrDefault() ?? throw new ProvisionException("This modpack has no published versions.");
        var files = version["files"]!.AsArray();
        var primary = files.FirstOrDefault(f => f!["primary"]?.GetValue<bool>() == true) ?? files.FirstOrDefault() ?? throw new ProvisionException("This modpack has no published versions.");
        var url = primary["url"]?.GetValue<string>() ?? throw new ProvisionException("Modpack file has no download URL.");
        var wantSha1 = primary["hashes"]?["sha1"]?.GetValue<string>() ?? "";

        var scratch = Path.Combine(Path.GetTempPath(), "craftpanel-modpack-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(scratch);
        try
        {
            var archive = Path.Combine(scratch, "pack.mrpack");
            await Http.DownloadAsync(url, archive, "the modpack", progress, ct);
            if (wantSha1.Length > 0 && !Http.Sha1Hex(archive).Equals(wantSha1, StringComparison.OrdinalIgnoreCase))
                throw new ProvisionException("Modpack checksum mismatch — deleted rather than trust it.");

            progress?.Report(new("index", "Reading the modpack manifest…", null));
            using var zip = ZipFile.OpenRead(archive);
            var indexEntry = zip.GetEntry("modrinth.index.json") ?? throw new ProvisionException("This file doesn't look like a Modrinth modpack (.mrpack).");
            JsonNode index;
            using (var s = indexEntry.Open()) index = JsonNode.Parse(s) ?? throw new ProvisionException("This file doesn't look like a Modrinth modpack (.mrpack).");
            var deps = index["dependencies"]?.AsObject() ?? throw new ProvisionException("This modpack doesn't specify its dependencies.");
            var mc = deps["minecraft"]?.GetValue<string>() ?? throw new ProvisionException("This modpack doesn't specify a Minecraft version.");

            Loader loader; string? loaderVersion;
            if (deps["fabric-loader"] is { } fl) { loader = Loader.Fabric; loaderVersion = fl.GetValue<string>(); }
            else if (deps["neoforge"] is { } nf) { loader = Loader.NeoForge; loaderVersion = nf.GetValue<string>(); }
            else if (deps["forge"] is { } fg) { loader = Loader.Forge; loaderVersion = $"{mc}-{fg.GetValue<string>()}"; }
            else if (deps["quilt-loader"] is not null) throw new ProvisionException("This modpack needs Quilt, which OMNIServers doesn't provision yet.");
            else { loader = Loader.Vanilla; loaderVersion = null; }

            java = await Provisioner.EnsureJavaAsync(java, JavaProbe.RequiredJava(mc), mc, progress, ct);
            var spec = new CreateSpec(loader, mc, loaderVersion, dir, name, ramMB, java);
            progress?.Report(new("loader", $"Setting up {loader.Label()} {mc}…", null));
            var launch = loader switch
            {
                Loader.Vanilla => await Provisioner.DownloadVanilla(spec, dir, progress, ct),
                Loader.Fabric => await Provisioner.DownloadFabric(spec, dir, progress, ct),
                _ => await Provisioner.RunInstaller(spec, dir, java, progress, ct),
            };
            File.WriteAllText(Path.Combine(dir, "eula.txt"), "# Accepted via OMNIServers — https://aka.ms/MinecraftEULA\neula=true\n");

            var wanted = index["files"]!.AsArray().Where(f => f!["env"]?["server"]?.GetValue<string>() != "unsupported").ToList();
            for (var i = 0; i < wanted.Count; i++)
            {
                var f = wanted[i]!;
                var path = f["path"]!.GetValue<string>();
                if (!SafeRelativePath(path)) continue;
                var src = f["downloads"]!.AsArray().Select(d => DownloadAllowed(d!.GetValue<string>())).FirstOrDefault(u => u is not null)
                    ?? throw new ProvisionException($"{path}: download host isn't allowed by the modpack format.");
                var sha1 = f["hashes"]?["sha1"]?.GetValue<string>(); var sha512 = f["hashes"]?["sha512"]?.GetValue<string>();
                if (sha1 is null && sha512 is null) throw new ProvisionException($"{path}: no checksum in the pack — refusing to install it.");
                var outPath = FileOps.Confine(dir, path);
                Directory.CreateDirectory(Path.GetDirectoryName(outPath)!);
                progress?.Report(new("mods", $"Installing mods… {i + 1}/{wanted.Count}", (i + 1) * 100 / Math.Max(1, wanted.Count)));
                await Http.DownloadAsync(src.AbsoluteUri, outPath, path, null, ct);
                if (sha1 is not null && !Http.Sha1Hex(outPath).Equals(sha1, StringComparison.OrdinalIgnoreCase))
                {
                    File.Delete(outPath);
                    throw new ProvisionException($"{path}: checksum mismatch — the download may be corrupted, try again.");
                }
            }

            progress?.Report(new("overrides", "Applying the pack's configs…", null));
            foreach (var prefix in new[] { "overrides", "server-overrides" })   // server-overrides wins: applied second
                MergeOverrides(zip, prefix, dir);

            await Provisioner.FirstBootAsync(spec, dir, java, launch, loader.ServerType(), progress, ct);
            Provisioner.ApplyStartingSettings(dir, false, Provisioner.PickFreePort(takenPorts), null, null, null, null, null);
            return new(loader.ServerType(), launch, mc, dir, java);
        }
        finally { try { Directory.Delete(scratch, true); } catch { } }
    }

    /// <summary>Copies <c>&lt;prefix&gt;/…</c> entries into the server folder: regular files only (no symlinks), every path confined.</summary>
    public static void MergeOverrides(ZipArchive zip, string prefix, string dir)
    {
        var start = prefix + "/";
        foreach (var e in zip.Entries)
        {
            if (!e.FullName.StartsWith(start, StringComparison.Ordinal)) continue;
            var rel = e.FullName[start.Length..];
            if (rel.Length == 0 || rel.EndsWith('/')) continue;
            if (!SafeRelativePath(rel)) continue;
            // a symlink entry (unix mode 0xA000) must never be materialised
            if (((e.ExternalAttributes >> 16) & 0xF000) == 0xA000) continue;
            var target = FileOps.Confine(dir, rel);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            e.ExtractToFile(target, overwrite: true);
        }
    }
}
