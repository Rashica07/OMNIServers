using CraftPanel.Core;
using Xunit;

namespace CraftPanel.Tests;

public class LogAnalyzerTests
{
    static string[] Ids(string s) => LogAnalyzer.Analyze(s).Select(f => f.Id).ToArray();

    [Fact] public void CleanLogHasNoFindings() => Assert.Empty(Ids("[12:00:05] [Server thread/INFO]: Done (4.2s)! For help, type \"help\""));
    [Fact] public void Eula() => Assert.Equal(["eula"], Ids("You need to agree to the EULA in order to run the server."));
    [Fact] public void PortClash() => Assert.Equal(["port"], Ids("**** FAILED TO BIND TO PORT! Address already in use"));
    [Fact] public void JavaVersion() => Assert.Contains("java-version", Ids("java.lang.UnsupportedClassVersionError: x"));
    [Fact] public void OutOfMemory() => Assert.Contains("oom", Ids("java.lang.OutOfMemoryError: Java heap space"));
    [Fact] public void MissingDependency() => Assert.Contains("dependency", Ids("Missing or unsupported mandatory dependencies: fabric-api"));
    [Fact] public void DuplicateMod() => Assert.Contains("duplicate-mod", Ids("Found duplicate mods: sodium"));
    [Fact] public void LagIsWarning() => Assert.False(LogAnalyzer.Analyze("Can't keep up! Is the server overloaded?")[0].IsError);
    [Fact] public void SeveralAtOnce() => Assert.Equal(new[] { "oom", "port" }, Ids("Address already in use\njava.lang.OutOfMemoryError").OrderBy(x => x).ToArray());
}
