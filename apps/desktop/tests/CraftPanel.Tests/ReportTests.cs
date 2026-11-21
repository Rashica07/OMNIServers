using System.IO.Compression;
using CraftPanel.Core;
using CraftPanel.Core.Diagnostics;
using Xunit;

namespace CraftPanel.Tests;

public class ReportTests
{
    static string ReadEntry(string zip, string name)
    {
        using var z = ZipFile.OpenRead(zip);
        var e = z.GetEntry(name) ?? throw new Xunit.Sdk.XunitException($"{name} is not in the report");
        using var r = new StreamReader(e.Open());
        return r.ReadToEnd();
    }

    [Fact]
    public void RedactorRemovesNamesIpAddressesAndSecrets()
    {
        var r = new Redactor("kiqa", "SCHOOL-PC-07", @"C:\Users\kiqa");
        var text = @"Loaded C:\Users\kiqa\AppData\x on SCHOOL-PC-07 by kiqa. /203.0.113.5:54321 lost connection. Local 192.168.1.20 and 127.0.0.1. rcon.password=hunter2 password: abc123 token=xyz Minecraft 1.21.4 Java 21.0.5";
        var o = r.Apply(text);
        Assert.DoesNotContain("kiqa", o, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("SCHOOL-PC-07", o);
        Assert.DoesNotContain("203.0.113.5", o); Assert.DoesNotContain("192.168.1.20", o);
        Assert.DoesNotContain("hunter2", o); Assert.DoesNotContain("abc123", o); Assert.DoesNotContain("xyz", o);
        Assert.Contains("127.0.0.1", o);                      // not personal
        Assert.Contains("1.21.4", o); Assert.Contains("21.0.5", o);   // versions are not mistaken for addresses
        Assert.Contains("%USERPROFILE%", o);
    }

    [Fact]
    public void TheReportZipHasTheUsefulFilesAndNoSecrets()
    {
        using var t = new TempDir();
        var old = AppPaths.DataOverride; AppPaths.DataOverride = Path.Combine(t.Path, "data");
        try
        {
            File.WriteAllText(Path.Combine(AppPaths.LogsDir, "crash.log"), "[2026-10-22] ui — boom\nrcon.password=topsecret\nplayer at 10.0.0.7 failed");
            File.WriteAllText(Path.Combine(AppPaths.DataDir, "settings.json"), "{\"installId\":\"SHOULD-NOT-APPEAR\"}");
            File.WriteAllText(Path.Combine(AppPaths.DataDir, "license.json"), "{\"key\":\"CP-SECRET-KEY\"}");
            var i = new ReportInput { Description = "It crashes when I press Start", AppVersion = "2.8.0", Error = "NullReferenceException at X" };
            i.Checks.Add(new DoctorCheck("Java", CheckLevel.Warn, "No Java found."));
            i.Servers.Add(new ReportServer("My Server", "Paper", "1.21.4", 4096, true, ["[12:00:01] Starting", "[12:00:02] password=hunter2", "Steve joined from /8.8.4.4:5000"]));
            i.ConsoleOf = "My Server";

            var zip = ReportBuilder.Save(i, Path.Combine(t.Path, "out"));
            Assert.True(File.Exists(zip));
            using (var z = ZipFile.OpenRead(zip)) Assert.Equal(["console.txt", "crash.log", "report.txt"], z.Entries.Select(e => e.FullName).Order().ToArray());
            var all = ReadEntry(zip, "report.txt") + ReadEntry(zip, "crash.log") + ReadEntry(zip, "console.txt");
            Assert.Contains("It crashes when I press Start", all); Assert.Contains("boom", all); Assert.Contains("Starting", all);
            Assert.Contains("[Warn] Java: No Java found.", all);
            foreach (var secret in new[] { "topsecret", "hunter2", "SHOULD-NOT-APPEAR", "CP-SECRET-KEY", "10.0.0.7", "8.8.4.4" })
                Assert.DoesNotContain(secret, all);
        }
        finally { AppPaths.DataOverride = old; }
    }

    [Fact]
    public void OnlyTheChosenServersConsoleIsAttachedAndItIsCapped()
    {
        using var t = new TempDir();
        var old = AppPaths.DataOverride; AppPaths.DataOverride = Path.Combine(t.Path, "data");
        try
        {
            var i = new ReportInput { ConsoleOf = "B" };
            i.Servers.Add(new ReportServer("A", "Paper", "1.21", 2048, false, ["A-LINE"]));
            i.Servers.Add(new ReportServer("B", "Paper", "1.21", 2048, false, Enumerable.Range(0, 2000).Select(n => $"B-LINE-{n}").ToList()));
            var zip = ReportBuilder.Save(i, t.Path);
            var console = ReadEntry(zip, "console.txt");
            Assert.DoesNotContain("A-LINE", console);
            Assert.Equal(ReportBuilder.MaxConsoleLines, console.Split('\n').Length);
            Assert.Contains("B-LINE-1999", console); Assert.DoesNotContain("B-LINE-0\n", console + "\n");
        }
        finally { AppPaths.DataOverride = old; }
    }

    [Fact]
    public void Quick_report_link_is_a_blank_github_issue_with_only_version_and_os()
    {
        var url = ReportBuilder.NewIssueUrl("2.8.1");
        Assert.StartsWith("https://github.com/Rashica07/OMNIServers/issues/new?body=", url);
        var body = Uri.UnescapeDataString(url.Split("body=")[1]);
        Assert.Contains("CraftPanel 2.8.1", body);
        Assert.DoesNotContain(Environment.UserName, body.Replace("CraftPanel", ""), StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Quick_report_carries_the_redacted_log_tail_and_stays_short_enough_for_a_link()
    {
        var dir = Directory.CreateTempSubdirectory().FullName;
        try
        {
            var log = Path.Combine(dir, "crash.log");
            File.WriteAllText(log, string.Join("\n", Enumerable.Range(0, 400).Select(i => $"line {i} C:\\Users\\{Environment.UserName}\\x password=hunter2 from 192.168.1.20")));
            var tail = ReportBuilder.RedactedTail(log);
            Assert.DoesNotContain("hunter2", tail);
            Assert.DoesNotContain("192.168.1.20", tail);
            Assert.Contains("line 399", tail);
            Assert.DoesNotContain("line 100 ", tail);
            var url = ReportBuilder.NewIssueUrl("2.8.2", tail, tail);
            Assert.True(url.Length <= 7100, url.Length.ToString());
            Assert.Contains("crash.log", Uri.UnescapeDataString(url));
            Assert.Equal("", ReportBuilder.RedactedTail(Path.Combine(dir, "missing.log")));
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public void TheIssueLinkCarriesOnlyAShortSummary()
    {
        var url = ReportBuilder.IssueUrl("Crash on start", new string('x', 9000));
        Assert.StartsWith("https://github.com/Rashica07/OMNIServers/issues/new?title=Crash%20on%20start&body=", url);
        Assert.True(url.Length < 6500);
        Assert.Contains("attach", Uri.UnescapeDataString(url));
    }

    [Fact]
    public void DataFolderChoiceCoversNormalPortableAndLockedDownPcs()
    {
        var perUser = Path.Combine("C", "AppData", "CraftPanel"); var exe = Path.Combine("D", "usb"); var temp = Path.Combine("T", "tmp");
        bool Everything(string _) => true; bool Nothing(string _) => false;

        // normal PC
        Assert.Equal((perUser, DataMode.Normal), AppPaths.ChooseRoot(perUser, exe, temp, Everything, Nothing));
        // portable.txt beside the program wins even when the normal folder works
        var p = AppPaths.ChooseRoot(perUser, exe, temp, Everything, f => f == Path.Combine(exe, "portable.txt"));
        Assert.Equal((Path.Combine(exe, "CraftPanelData"), DataMode.Portable), p);
        // AppData locked: use a folder beside the program
        var f1 = AppPaths.ChooseRoot(perUser, exe, temp, d => d.StartsWith(exe), Nothing);
        Assert.Equal((Path.Combine(exe, "CraftPanelData"), DataMode.Fallback), f1);
        // everything locked except temp
        var f2 = AppPaths.ChooseRoot(perUser, exe, temp, d => d.StartsWith(temp), Nothing);
        Assert.Equal((Path.Combine(temp, "CraftPanelData"), DataMode.Fallback), f2);
        // no known exe folder
        Assert.Equal(DataMode.Fallback, AppPaths.ChooseRoot(perUser, null, temp, Nothing, Nothing).Mode);
    }

    [Fact]
    public void CanWriteIsFalseForAFolderThatCannotBeCreated()
    {
        using var t = new TempDir();
        var blocker = t.Write("a-file");                                  // a file where a folder would have to go
        Assert.False(AppPaths.CanWrite(Path.Combine(blocker, "sub")));
        Assert.True(AppPaths.CanWrite(Path.Combine(t.Path, "ok")));
    }

    [Fact]
    public async Task HealthCheckReportsWhereFilesAreKept()
    {
        using var t = new TempDir();
        var old = AppPaths.DataOverride; AppPaths.DataOverride = Path.Combine(t.Path, "data");
        try
        {
            var checks = await Doctor.RunAsync(Path.Combine(t.Path, "servers"));
            var saving = Assert.Single(checks, c => c.Name == "Saving files");
            Assert.Contains("custom data folder", saving.Detail);
            Assert.NotEqual(CheckLevel.Bad, saving.Level);
        }
        finally { AppPaths.DataOverride = old; }
    }
}
