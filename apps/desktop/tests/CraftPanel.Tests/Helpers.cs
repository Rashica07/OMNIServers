using CraftPanel.Core;

namespace CraftPanel.Tests;

public sealed class TempDir : IDisposable
{
    public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "cp-test-" + Guid.NewGuid().ToString("N")[..8]);
    public TempDir() => Directory.CreateDirectory(Path);
    public string Sub(string rel) { var p = System.IO.Path.Combine(Path, rel); Directory.CreateDirectory(System.IO.Path.GetDirectoryName(p)!); return p; }
    public string Write(string rel, string text = "x") { var p = Sub(rel); File.WriteAllText(p, text); return p; }
    public void Dispose() { try { Directory.Delete(Path, true); } catch { } }
    public override string ToString() => Path;
}
