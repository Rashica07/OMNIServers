using System.Security.Cryptography;
using System.Text.Json.Nodes;

namespace CraftPanel.Core;

/// <summary>One shared HttpClient plus the download/verify helpers every installer uses.</summary>
public static class Http
{
    public const string UserAgent = "CraftPanel/2.6 (server-manager)";

    public static HttpClient Client { get; set; } = Make();

    static HttpClient Make()
    {
        var handler = new SocketsHttpHandler { AutomaticDecompression = System.Net.DecompressionMethods.All, ConnectTimeout = TimeSpan.FromSeconds(15) };
        // Wine's SChannel handles TLS 1.2 reliably but TLS 1.3 only patchily; every service CraftPanel talks to speaks 1.2.
        if (Platform.IsWine) handler.SslOptions = new System.Net.Security.SslClientAuthenticationOptions { EnabledSslProtocols = System.Security.Authentication.SslProtocols.Tls12 };
        var c = new HttpClient(handler) { Timeout = TimeSpan.FromMinutes(10) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd(UserAgent);
        return c;
    }

    public static async Task<JsonNode> GetJsonAsync(string url, CancellationToken ct = default)
    {
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromSeconds(25));
            using var resp = await Client.GetAsync(url, cts.Token);
            resp.EnsureSuccessStatusCode();
            return JsonNode.Parse(await resp.Content.ReadAsStringAsync(cts.Token)) ?? throw new ProvisionException($"{url}: empty response");
        }
        catch (ProvisionException) { throw; }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception e) { throw new ProvisionException($"{url}: {e.Message}", e); }
    }

    /// <summary>
    /// Streams <paramref name="url"/> to <paramref name="dest"/> (via a temp file, so an error
    /// page or a partial download is never left behind as server.jar).
    /// </summary>
    public static async Task DownloadAsync(string url, string dest, string label, IProgress<ProvisionProgress>? progress = null, CancellationToken ct = default)
    {
        progress?.Report(new("download", $"Downloading {label}…", 0));
        var tmp = dest + ".part";
        try
        {
            using var resp = await Client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct);
            if (!resp.IsSuccessStatusCode)
                throw new ProvisionException($"download of {label} failed (HTTP {(int)resp.StatusCode})");
            var total = resp.Content.Headers.ContentLength;
            await using (var src = await resp.Content.ReadAsStreamAsync(ct))
            await using (var dst = File.Create(tmp))
            {
                var buf = new byte[81920];
                long done = 0; int lastPct = -1;
                int n;
                while ((n = await src.ReadAsync(buf, ct)) > 0)
                {
                    await dst.WriteAsync(buf.AsMemory(0, n), ct);
                    done += n;
                    if (total is > 0)
                    {
                        var pct = (int)(done * 100 / total.Value);
                        if (pct != lastPct) { lastPct = pct; progress?.Report(new("download", $"Downloading {label}…", pct)); }
                    }
                }
            }
            File.Move(tmp, dest, overwrite: true);
            progress?.Report(new("download", $"Downloaded {label} ({new FileInfo(dest).Length / 1_048_576} MB)", 100));
        }
        catch (ProvisionException) { TryDelete(tmp); throw; }
        catch (OperationCanceledException) { TryDelete(tmp); throw; }
        catch (Exception e) { TryDelete(tmp); throw new ProvisionException($"download failed: {e.Message}", e); }
    }

    public static string Sha256Hex(string file) { using var s = File.OpenRead(file); return Convert.ToHexStringLower(SHA256.HashData(s)); }
    public static string Sha1Hex(string file) { using var s = File.OpenRead(file); return Convert.ToHexStringLower(SHA1.HashData(s)); }

    static void TryDelete(string p) { try { File.Delete(p); } catch { } }
}
