using System.IO.Compression;
using System.Net;
using System.Text.Json.Nodes;
using CraftPanel.Core;
using CraftPanel.Core.Adapters;
using Xunit;

namespace CraftPanel.Tests;

[Collection("Http")]
public class GameInstallerTests : IDisposable
{
    readonly string dir = Path.Combine(Path.GetTempPath(), "cp-inst-" + Guid.NewGuid().ToString("N"));
    readonly HttpClient old = Http.Client;
    public void Dispose() { Http.Client = old; try { Directory.Delete(dir, true); } catch { } }

    sealed class Fake(Func<string, byte[]> serve) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage r, CancellationToken ct) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(serve(r.RequestUri!.ToString())) });
    }

    static byte[] Zip(params (string path, string body)[] files)
    {
        using var ms = new MemoryStream();
        using (var z = new ZipArchive(ms, ZipArchiveMode.Create, true))
            foreach (var (p, b) in files) { using var w = new StreamWriter(z.CreateEntry(p).Open()); w.Write(b); }
        return ms.ToArray();
    }

    [Fact] public void ParsesFiveMLink() => Assert.Equal("https://x/server.zip", GameInstaller.ParseFiveMUrl(JsonNode.Parse("{\"latest_download\":\"https://x/server.zip\"}")!));
    [Fact] public void ParsesTerrariaName() => Assert.Equal("terraria-server-1458.zip", GameInstaller.ParseTerrariaFile(JsonNode.Parse("[\"terraria-server-1458.zip\",\"terraria-server-1458.zip\"]")!));

    [Fact] public async Task TerrariaInstallPicksThisOsAndWritesConfig()
    {
        var zip = Zip(("1458/Windows/TerrariaServer.exe", "w"), ("1458/Linux/TerrariaServer.bin.x86_64", "l"), ("1458/Mac/TerrariaServer.bin.osx", "m"));
        Http.Client = new HttpClient(new Fake(u => u.Contains("names") ? "[\"terraria-server-1458.zip\"]"u8.ToArray() : zip));
        var made = await GameInstaller.CreateAsync(ServerType.Terraria, dir, "My World");
        Assert.Equal(ServerType.Terraria, made.ServerType);
        Assert.True(File.Exists(Path.Combine(dir, made.LaunchTarget)));
        Assert.True(File.Exists(Path.Combine(dir, "serverconfig.txt")));
        Assert.False(Directory.Exists(Path.Combine(dir, ".stage")));
    }

    [Fact] public async Task RefusesNonEmptyFolder()
    {
        Directory.CreateDirectory(dir); File.WriteAllText(Path.Combine(dir, "x"), "");
        await Assert.ThrowsAsync<ProvisionException>(() => GameInstaller.CreateAsync(ServerType.Terraria, dir, "x"));
    }

    [Fact] public async Task RefusesNonGame() => await Assert.ThrowsAsync<ArgumentException>(() => GameInstaller.CreateAsync(ServerType.Paper, dir, "x"));
}
