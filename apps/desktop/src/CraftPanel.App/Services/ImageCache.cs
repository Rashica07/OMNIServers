using Avalonia.Media.Imaging;
using CraftPanel.Core;

namespace CraftPanel.App.Services;

/// <summary>Downloads and decodes small remote images (mod icons) once each.</summary>
public static class ImageCache
{
    static readonly Dictionary<string, Task<Bitmap?>> Cache = [];
    static readonly SemaphoreSlim Gate = new(4);

    public static Task<Bitmap?> LoadAsync(string? url)
    {
        if (string.IsNullOrEmpty(url) || !url.StartsWith("https://", StringComparison.Ordinal)) return Task.FromResult<Bitmap?>(null);
        lock (Cache)
        {
            if (!Cache.TryGetValue(url, out var t)) Cache[url] = t = Fetch(url);
            return t;
        }
    }

    static async Task<Bitmap?> Fetch(string url)
    {
        await Gate.WaitAsync();
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            var bytes = await Http.Client.GetByteArrayAsync(url, cts.Token);
            using var ms = new MemoryStream(bytes);
            return Bitmap.DecodeToWidth(ms, 96);
        }
        catch { return null; }
        finally { Gate.Release(); }
    }
}
