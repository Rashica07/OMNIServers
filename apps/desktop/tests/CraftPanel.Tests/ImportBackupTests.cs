using System.IO.Compression;
using System.Text.Json;
using CraftPanel.Core;
using CraftPanel.Core.Backups;
using Xunit;

namespace CraftPanel.Tests;

/// <summary>A backup made on someone else's PC (their .zip and .json) added to this PC's server, then restored.</summary>
public class ImportBackupTests
{
    static string Server(TempDir t, string name, string levelDat, string mod, bool props = true)
    {
        var dir = Path.Combine(t.Path, name);
        Directory.CreateDirectory(Path.Combine(dir, "world")); Directory.CreateDirectory(Path.Combine(dir, "mods"));
        if (props) File.WriteAllText(Path.Combine(dir, "server.properties"), "level-name=world\nmotd=" + name + "\n");
        File.WriteAllText(Path.Combine(dir, "world", "level.dat"), levelDat);
        File.WriteAllText(Path.Combine(dir, "mods", mod), "MOD:" + mod);
        return dir;
    }

    /// <summary>Their latest backup, copied to a "USB stick" folder the way a friend would send it.</summary>
    static (string zip, string json, Backup meta) FriendsBackup(TempDir t, string label = "friday night")
    {
        var friend = Server(t, "friend-pc", "FRIENDS-LATEST-WORLD", "fabric-api.jar");
        var meta = BackupManager.BackupNow(friend, label, "manual");
        var stick = Path.Combine(t.Path, "stick"); Directory.CreateDirectory(stick);
        var zip = Path.Combine(stick, meta.Id + ".zip"); var json = Path.Combine(stick, meta.Id + ".json");
        File.Copy(Path.Combine(BackupManager.Root(friend), meta.Id + ".zip"), zip);
        File.Copy(Path.Combine(BackupManager.Root(friend), meta.Id + ".json"), json);
        return (zip, json, meta);
    }

    static string MakeZip(TempDir t, string name, params (string entry, string text)[] files)
    {
        var path = Path.Combine(t.Path, name);
        using (var z = ZipFile.Open(path, ZipArchiveMode.Create))
            foreach (var (entry, text) in files) { var e = z.CreateEntry(entry); using var w = new StreamWriter(e.Open()); w.Write(text); }
        return path;
    }

    [Fact]
    public void AFriendsLatestBackupImportsAndRestoresOntoMyOlderServer()
    {
        using var t = new TempDir();
        var (zip, json, theirs) = FriendsBackup(t);
        var mine = Server(t, "my-pc", "MY-OLDER-WORLD", "my-old-mod.jar");
        var mineOwn = BackupManager.BackupNow(mine, "mine", "manual");

        var imported = BackupManager.ImportBackup(mine, zip, json);
        Assert.Equal("imported", imported.Trigger);
        Assert.Equal("friday night", imported.Label);                 // their label and their time are kept
        Assert.Equal(theirs.CreatedAt, imported.CreatedAt);
        Assert.True(imported.Verified);
        Assert.Equal(2, BackupManager.List(mine).Count);
        Assert.Equal(zip is null ? 0 : new FileInfo(zip).Length, imported.SizeBytes);
        Assert.Equal(mineOwn.Id, BackupManager.List(mine).Single(b => b.Trigger != "imported").Id);   // mine is untouched

        BackupManager.Restore(mine, imported.Id);
        Assert.Equal("FRIENDS-LATEST-WORLD", File.ReadAllText(Path.Combine(mine, "world", "level.dat")));
        Assert.True(File.Exists(Path.Combine(mine, "mods", "fabric-api.jar")));
        Assert.Contains(BackupManager.List(mine), b => b.Trigger == "pre-restore");               // what I had was backed up first
    }

    [Fact]
    public void TheJsonIsFoundNextToTheZipAndIsOptional()
    {
        using var t = new TempDir();
        var (zip, _, theirs) = FriendsBackup(t);
        var mine = Server(t, "my-pc", "X", "a.jar");
        Assert.Equal(Path.ChangeExtension(zip, ".json"), BackupManager.SiblingJson(zip));
        Assert.Equal(theirs.CreatedAt, BackupManager.ImportBackup(mine, zip, BackupManager.SiblingJson(zip)).CreatedAt);

        var mine2 = Server(t, "my-pc-2", "X", "a.jar");               // zip alone: dated by the file instead
        File.SetLastWriteTimeUtc(zip, new DateTime(2026, 3, 4, 12, 0, 0, DateTimeKind.Utc));
        var b = BackupManager.ImportBackup(mine2, zip, null);
        Assert.Equal(new DateTimeOffset(2026, 3, 4, 12, 0, 0, TimeSpan.Zero).ToUnixTimeSeconds(), b.CreatedAt);
        Assert.Null(b.Label);
    }

    [Fact]
    public void ADamagedOrStrangeJsonIsIgnoredNotTrusted()
    {
        using var t = new TempDir();
        var (zip, json, _) = FriendsBackup(t);
        var mine = Server(t, "my-pc", "X", "a.jar");
        File.WriteAllText(json, "{ this is not json");
        Assert.NotNull(BackupManager.ImportBackup(mine, zip, json));

        var mine2 = Server(t, "my-pc-2", "X", "a.jar");
        File.WriteAllText(json, JsonSerializer.Serialize(new { id = "../../evil", created_at = 4_000_000_000L, label = "bad\u0007label\n", trigger = "pre-restore", size_bytes = 1 }));
        var b = BackupManager.ImportBackup(mine2, zip, json);
        Assert.DoesNotContain("..", b.Id);                             // ids are always made here
        Assert.True(b.CreatedAt < DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 100_000);   // a time far in the future is not believed
        Assert.Equal("imported", b.Trigger);                           // their trigger can't make it exempt/non-exempt by itself
        Assert.DoesNotContain('\u0007', b.Label ?? "");
        Assert.True(File.Exists(Path.Combine(BackupManager.Root(mine2), b.Id + ".zip")));
        Assert.True(b.SizeBytes > 1);                                  // the real size, not the one the json claims
    }

    [Fact]
    public void ImportingTheSameFileTwiceIsRefused()
    {
        using var t = new TempDir();
        var (zip, json, _) = FriendsBackup(t);
        var mine = Server(t, "my-pc", "X", "a.jar");
        BackupManager.ImportBackup(mine, zip, json);
        var e = Assert.Throws<ProvisionException>(() => BackupManager.ImportBackup(mine, zip, json));
        Assert.Contains("already imported", e.Message);
        Assert.Single(BackupManager.List(mine));
    }

    [Theory]
    [InlineData("../evil.txt")]
    [InlineData("world/../../evil.txt")]
    [InlineData("/etc/passwd")]
    [InlineData("C:/Windows/evil.dll")]
    [InlineData("craftpanel-backups/planted.zip")]
    [InlineData("craftpanel-snapshots/x/world/level.dat")]
    [InlineData(".craftpanel-pre-restore-1/world/level.dat")]
    public void ZipsThatReachOutsideTheServerFolderAreRefused(string entry)
    {
        using var t = new TempDir();
        var zip = MakeZip(t, "evil.zip", ("server.properties", "a=b"), (entry, "x"));
        var mine = Server(t, "my-pc", "X", "a.jar");
        var e = Assert.Throws<ProvisionException>(() => BackupManager.ImportBackup(mine, zip));
        Assert.Contains("outside the server folder", e.Message);
        Assert.Empty(BackupManager.List(mine));
        Assert.False(Directory.Exists(BackupManager.Root(mine)) && Directory.EnumerateFiles(BackupManager.Root(mine)).Any());   // nothing was copied in
    }

    [Fact]
    public void FilesThatAreNotServerBackupsAreRefusedWithAReason()
    {
        using var t = new TempDir();
        var mine = Server(t, "my-pc", "X", "a.jar");
        var notZip = t.Write("notes.zip", "plain text pretending");
        Assert.Contains("valid .zip", Assert.Throws<ProvisionException>(() => BackupManager.ImportBackup(mine, notZip)).Message);
        var photos = MakeZip(t, "photos.zip", ("holiday/img1.jpg", "x"), ("readme.txt", "hi"));
        Assert.Contains("doesn't look like a Minecraft server", Assert.Throws<ProvisionException>(() => BackupManager.ImportBackup(mine, photos)).Message);
        Assert.Throws<ProvisionException>(() => BackupManager.ImportBackup(mine, Path.Combine(t.Path, "missing.zip")));
        Assert.Empty(BackupManager.List(mine));
    }

    [Fact]
    public void AnImportedBackupSurvivesTheAutomaticCleanup()
    {
        using var t = new TempDir();
        var (zip, json, _) = FriendsBackup(t);                         // an old backup by date
        var mine = Server(t, "my-pc", "X", "a.jar");
        var imported = BackupManager.ImportBackup(mine, zip, json);
        for (var i = 0; i < 3; i++) { BackupManager.BackupNow(mine, null, "manual"); Thread.Sleep(1100); }
        BackupManager.Prune(mine, keep: 1);
        Assert.Contains(BackupManager.List(mine), b => b.Id == imported.Id);        // "keep newest 1" must not eat the friend's backup
        Assert.Equal(2, BackupManager.List(mine).Count);
        BackupManager.PruneTiered(mine, 1, 1, DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 90 * 86400);
        Assert.Contains(BackupManager.List(mine), b => b.Id == imported.Id);
    }

    [Fact]
    public void InspectionReportsWhatIsInsideBeforeAnythingIsCopied()
    {
        using var t = new TempDir();
        var (zip, _, _) = FriendsBackup(t);
        var info = BackupManager.InspectZip(zip);
        Assert.True(info.HasWorld); Assert.True(info.HasServerProperties); Assert.Equal(1, info.Mods); Assert.Null(info.UnsafeEntry);
        Assert.True(info.LooksLikeAServer);
    }
}
