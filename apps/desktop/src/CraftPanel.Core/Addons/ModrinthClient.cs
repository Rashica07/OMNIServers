using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace CraftPanel.Core.Addons;

public sealed record ModrinthHit(string ProjectId, string Slug, string Title, string Description, int Downloads, string? IconUrl,
    string ProjectType, IReadOnlyList<string> Categories, bool Installed, bool Compatible, string ServerSide, string ClientSide);

public sealed record ModrinthSearchResult(List<ModrinthHit> Hits, int Total);

public sealed class UpdateInfo
{
    [JsonPropertyName("version_id")] public string VersionId { get; set; } = "";
    [JsonPropertyName("version_number")] public string VersionNumber { get; set; } = "";
}

/// <summary>One installed add-on, in the same <c>.craftpanel-modrinth.json</c> format the Mac app writes.</summary>
public sealed class InstalledEntry
{
    [JsonPropertyName("project_id")] public string ProjectId { get; set; } = "";
    [JsonPropertyName("slug")] public string Slug { get; set; } = "";
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("filename")] public string Filename { get; set; } = "";
    [JsonPropertyName("version_id")] public string VersionId { get; set; } = "";
    [JsonPropertyName("version_number")] public string VersionNumber { get; set; } = "";
    [JsonPropertyName("dependency")] public bool Dependency { get; set; }
    [JsonPropertyName("update")] public UpdateInfo? Update { get; set; }
}

public sealed record ModrinthInstallResult(List<string> Installed, List<string> Skipped);

/// <summary>Modrinth search/install/update for mods, plugins, datapacks and resource packs (SHA-1 verified, symlink/traversal-safe names).</summary>
public static class ModrinthClient
{
    const string Api = "https://api.modrinth.com/v2";
    const string ManifestName = ".craftpanel-modrinth.json";
    static readonly JsonSerializerOptions Json = new() { WriteIndented = false };

    public static string LoaderFacet(ServerType t) => t switch
    {
        ServerType.Fabric => "fabric", ServerType.Forge => "forge", ServerType.NeoForge => "neoforge",
        ServerType.Paper => "paper", ServerType.Spigot => "spigot", _ => "datapack",
    };

    public static string ContentDir(string dir, ServerType type, string projectType)
    {
        if (projectType == "datapack") return Path.Combine(dir, Properties.Load(dir).GetOr("level-name", "world"), "datapacks");
        return type.UsesPlugins() ? Path.Combine(dir, "plugins") : Path.Combine(dir, "mods");
    }

    static string ManifestPath(string dir) => Path.Combine(dir, ManifestName);

    public static List<InstalledEntry> Installed(string dir)
    {
        try { return JsonSerializer.Deserialize<List<InstalledEntry>>(File.ReadAllText(ManifestPath(dir)), Json) ?? []; } catch { return []; }
    }

    static void WriteManifest(string dir, List<InstalledEntry> list) => AppPaths.WriteAtomic(ManifestPath(dir), JsonSerializer.Serialize(list, Json));

    // ---- search ----------------------------------------------------------------------

    public static async Task<ModrinthSearchResult> SearchAsync(string serverDir, ServerType type, string query, string projectType,
        string? category, string? mcVersion, int offset, CancellationToken ct = default)
    {
        var lf = LoaderFacet(type);
        // Modrinth files real Paper/Spigot plugins under a separate "plugin" project_type facet.
        var searchType = projectType == "mod" && type.UsesPlugins() ? "plugin" : projectType;
        var facets = new List<string> { $"[\"project_type:{searchType}\"]" };
        if (projectType is not ("datapack" or "resourcepack"))
        {
            facets.Add($"[\"categories:{lf}\"]");
            facets.Add("[\"server_side:required\",\"server_side:optional\"]");
        }
        if (!string.IsNullOrEmpty(category)) facets.Add($"[\"categories:{category}\"]");
        var url = $"{Api}/search?query={Uri.EscapeDataString(query)}&facets={Uri.EscapeDataString("[" + string.Join(",", facets) + "]")}"
            + $"&limit=30&offset={offset}&index={(query.Length == 0 ? "downloads" : "relevance")}";
        var raw = await Http.GetJsonAsync(url, ct);
        var mine = Installed(serverDir).Select(e => e.ProjectId).ToHashSet();
        var hits = raw["hits"]!.AsArray().Select(h =>
        {
            var versions = h!["versions"]?.AsArray().Select(v => v!.GetValue<string>()).ToList() ?? [];
            var id = h["project_id"]!.GetValue<string>();
            return new ModrinthHit(id, h["slug"]!.GetValue<string>(), h["title"]!.GetValue<string>(), h["description"]?.GetValue<string>() ?? "",
                h["downloads"]?.GetValue<int>() ?? 0, h["icon_url"]?.GetValue<string>(), h["project_type"]?.GetValue<string>() ?? "mod",
                h["categories"]?.AsArray().Select(c => c!.GetValue<string>()).ToList() ?? [], mine.Contains(id),
                mcVersion is null || versions.Contains(mcVersion), h["server_side"]?.GetValue<string>() ?? "unknown", h["client_side"]?.GetValue<string>() ?? "unknown");
        }).ToList();
        // compatible first, relevance order within each group
        hits = hits.Select((h, i) => (h, i)).OrderBy(x => x.h.Compatible ? 0 : 1).ThenBy(x => x.i).Select(x => x.h).ToList();
        return new(hits, raw["total_hits"]?.GetValue<int>() ?? hits.Count);
    }

    // ---- install ---------------------------------------------------------------------

    static async Task<JsonNode> BestVersion(string project, string loader, string? mcVersion, string projectType, CancellationToken ct)
    {
        var loaders = projectType switch { "datapack" => "datapack", "resourcepack" => "minecraft", _ => loader };
        var url = $"{Api}/project/{Uri.EscapeDataString(project)}/version?loaders={Uri.EscapeDataString($"[\"{loaders}\"]")}";
        if (mcVersion is not null) url += $"&game_versions={Uri.EscapeDataString($"[\"{mcVersion}\"]")}";
        var arr = (await Http.GetJsonAsync(url, ct)).AsArray();
        return arr.Count > 0 ? arr[0]! : throw new ProvisionException("no version of this compatible with your loader + Minecraft version");
    }

    static JsonNode? PrimaryFile(JsonNode v) => v["files"]!.AsArray().FirstOrDefault(f => f!["primary"]?.GetValue<bool>() == true) ?? v["files"]!.AsArray().FirstOrDefault();

    static async Task<string> DownloadFile(JsonNode f, string destDir, CancellationToken ct)
    {
        Directory.CreateDirectory(destDir);
        var name = FileOps.SafeFileName(f["filename"]!.GetValue<string>());
        var dest = Path.Combine(destDir, name);
        await Http.DownloadAsync(f["url"]!.GetValue<string>(), dest, name, null, ct);
        if (f["hashes"]?["sha1"]?.GetValue<string>() is { } want && !Http.Sha1Hex(dest).Equals(want, StringComparison.OrdinalIgnoreCase))
        {
            File.Delete(dest);
            throw new ProvisionException($"{name}: checksum mismatch");
        }
        return name;
    }

    public static async Task<HashSet<string>> SupportedVersionsAsync(string project, string loader, CancellationToken ct = default)
    {
        var arr = (await Http.GetJsonAsync($"{Api}/project/{project}/version?loaders={Uri.EscapeDataString($"[\"{loader}\"]")}", ct)).AsArray();
        return arr.SelectMany(v => v!["game_versions"]!.AsArray().Select(g => g!.GetValue<string>())).ToHashSet();
    }

    public static async Task<ModrinthInstallResult> InstallAsync(string dir, ServerType type, string projectId, string projectType, string? mcVersion, CancellationToken ct = default)
    {
        var loader = LoaderFacet(type);
        var manifest = Installed(dir);
        var have = manifest.Select(m => m.ProjectId).ToHashSet();
        var installed = new List<string>(); var skipped = new List<string>();
        var queue = new Stack<(string Id, bool IsDep)>(); queue.Push((projectId, false));
        var seen = new HashSet<string>();
        while (queue.Count > 0)
        {
            var (pid, isDep) = queue.Pop();
            if (!seen.Add(pid)) continue;
            if (have.Contains(pid)) { skipped.Add(pid); continue; }
            var proj = await Http.GetJsonAsync($"{Api}/project/{Uri.EscapeDataString(pid)}", ct);
            var ptype = isDep ? "mod" : projectType;
            var title = proj["title"]!.GetValue<string>();
            JsonNode ver;
            try { ver = await BestVersion(pid, loader, mcVersion, ptype, ct); }
            catch (ProvisionException e) { throw new ProvisionException($"{title}: {e.Message}"); }
            var file = PrimaryFile(ver) ?? throw new ProvisionException($"{title}: version has no file");
            var filename = await DownloadFile(file, ContentDir(dir, type, ptype), ct);
            manifest.Add(new InstalledEntry
            {
                ProjectId = proj["id"]!.GetValue<string>(), Slug = proj["slug"]!.GetValue<string>(), Title = title, Filename = filename,
                VersionId = ver["id"]!.GetValue<string>(), VersionNumber = ver["version_number"]!.GetValue<string>(), Dependency = isDep,
            });
            have.Add(proj["id"]!.GetValue<string>());
            installed.Add(title);
            foreach (var d in ver["dependencies"]?.AsArray() ?? [])
            {
                if (d!["dependency_type"]?.GetValue<string>() != "required") continue;
                if (d["project_id"]?.GetValue<string>() is { } dp) queue.Push((dp, true));
            }
        }
        WriteManifest(dir, manifest);
        return new(installed, skipped);
    }

    /// <summary>
    /// Points the server at a resource pack (players download it on join): sets resource-pack, its SHA-1 and the require flag in
    /// server.properties. The pack file itself stays on Modrinth's CDN.
    /// </summary>
    public static async Task<string> InstallResourcepackAsync(string dir, string projectId, string? mcVersion, bool required, CancellationToken ct = default)
    {
        var ver = await BestVersion(projectId, "minecraft", mcVersion, "resourcepack", ct);
        var file = PrimaryFile(ver) ?? throw new ProvisionException("That pack's version has no file.");
        var sha1 = file["hashes"]?["sha1"]?.GetValue<string>() ?? throw new ProvisionException("Modrinth didn't publish a hash for that file.");
        var url = file["url"]!.GetValue<string>();
        if (!url.StartsWith("https://", StringComparison.Ordinal)) throw new ProvisionException("The pack isn't served over HTTPS.");
        if (!File.Exists(Path.Combine(dir, "server.properties"))) throw new ProvisionException("Start the server once so it generates server.properties, then add a resource pack.");
        var p = Properties.Load(dir);
        p.Set("resource-pack", url); p.Set("resource-pack-sha1", sha1); p.Set("require-resource-pack", required ? "true" : "false");
        p.Save();
        return file["filename"]?.GetValue<string>() ?? "pack";
    }

    public static async Task<List<string>> GalleryAsync(string projectId, CancellationToken ct = default)
    {
        var j = await Http.GetJsonAsync($"{Api}/project/{Uri.EscapeDataString(projectId)}", ct);
        return j["gallery"]?.AsArray().Select(g => g!["url"]!.GetValue<string>()).ToList() ?? [];
    }

    // ---- installed list + updates ------------------------------------------------------

    static string TypeOf(InstalledEntry e) => e.Filename.Contains("datapack", StringComparison.OrdinalIgnoreCase) ? "datapack" : "mod";

    public static async Task<List<InstalledEntry>> CheckUpdatesAsync(string dir, ServerType type, string? mcVersion, CancellationToken ct = default)
    {
        var loader = LoaderFacet(type);
        var list = Installed(dir);
        foreach (var e in list)
        {
            try
            {
                var v = await BestVersion(e.ProjectId, loader, mcVersion, TypeOf(e), ct);
                e.Update = v["id"]!.GetValue<string>() != e.VersionId ? new UpdateInfo { VersionId = v["id"]!.GetValue<string>(), VersionNumber = v["version_number"]!.GetValue<string>() } : null;
            }
            catch (ProvisionException) { }
        }
        WriteManifest(dir, list);
        return list;
    }

    /// <summary>Trashes the old jar (never deletes); if the new download fails, puts it back.</summary>
    public static async Task UpdateOneAsync(string dir, ServerType type, string projectId, string? mcVersion, CancellationToken ct = default)
    {
        var list = Installed(dir);
        var e = list.FirstOrDefault(x => x.ProjectId == projectId) ?? throw new ProvisionException("not installed");
        var ver = await BestVersion(projectId, LoaderFacet(type), mcVersion, TypeOf(e), ct);
        var file = PrimaryFile(ver) ?? throw new ProvisionException("no file");
        var destDir = ContentDir(dir, type, TypeOf(e));
        var old = Path.Combine(destDir, FileOps.SafeFileName(e.Filename));
        var trashed = File.Exists(old) ? FileOps.MoveToTrash(old, Path.Combine(dir, ".craftpanel-trash")) : null;
        try { e.Filename = await DownloadFile(file, destDir, ct); }
        catch { if (trashed is not null) File.Move(trashed, old); throw; }
        e.VersionId = ver["id"]!.GetValue<string>(); e.VersionNumber = ver["version_number"]!.GetValue<string>(); e.Update = null;
        WriteManifest(dir, list);
    }

    public static void RemoveOne(string dir, ServerType type, string projectId)
    {
        var list = Installed(dir);
        var e = list.FirstOrDefault(x => x.ProjectId == projectId) ?? throw new ProvisionException("not installed");
        list.Remove(e);
        foreach (var b in new[] { ContentDir(dir, type, TypeOf(e)), Path.Combine(dir, "mods-disabled") })
        {
            var p = Path.Combine(b, FileOps.SafeFileName(e.Filename));
            if (File.Exists(p)) FileOps.MoveToTrash(p, Path.Combine(dir, ".craftpanel-trash"));
        }
        WriteManifest(dir, list);
    }
}
