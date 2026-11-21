using Avalonia.Headless.XUnit;
using CraftPanel.App.Services;
using CraftPanel.App.ViewModels;
using CraftPanel.App.Views;
using CraftPanel.Core;
using CraftPanel.Core.Backups;
using CraftPanel.Core.Network;
using CraftPanel.Core.Nbt;
using CraftPanel.Core.Diagnostics;
using CraftPanel.Core.Help;
using Xunit;

namespace CraftPanel.Tests;

/// <summary>Screens for snapshots, the tunnel, cross-play and the NBT editor — rendered headless and driven through their view-models.</summary>
public class FeatureUiTests
{
    static MainWindow Open(int index, ServerSection section, double height = 780)
    {
        CraftPanel.App.Services.Palette.Dark.Apply(Avalonia.Application.Current!);
        var rec = AppServices.Store.All[index];
        var w = new MainWindow { Width = 1180, Height = height };
        ((MainViewModel)w.DataContext!).Open(rec.Id, section);
        return w;
    }

    /// <summary>Runs an async command and waits until it has finished (commands are fire-and-forget by design).</summary>
    static async Task RunCmd(AsyncCommand c)
    {
        c.Execute(null);
        for (var i = 0; i < 300 && !c.CanExecute(null); i++) { await Task.Delay(20); Avalonia.Threading.Dispatcher.UIThread.RunJobs(); }
        await Task.Delay(30); Avalonia.Threading.Dispatcher.UIThread.RunJobs();
    }

    static T Section<T>(MainWindow w) where T : ViewModelBase => Assert.IsType<T>(Assert.IsType<ServerDetailViewModel>(((MainViewModel)w.DataContext!).Content).Section);

    static void Populate(string dir)
    {
        Directory.CreateDirectory(Path.Combine(dir, "world"));
        File.WriteAllText(Path.Combine(dir, "world", "level.dat"), "x");
        File.WriteAllBytes(Path.Combine(dir, "world", "region.mca"), new byte[200_000]);
        File.WriteAllText(Path.Combine(dir, "ops.json"), "[]");
    }

    [AvaloniaFact]
    public async Task BackupsTabTakesAndRestoresSnapshots()
    {
        using var t = Shot.Seed();
        var rec = AppServices.Store.All[0];
        Populate(rec.Path);
        SnapshotManager.SnapshotNow(rec.Path, "manual");
        File.WriteAllText(Path.Combine(rec.Path, "ops.json"), "[{\"name\":\"Steve\"}]");
        SnapshotManager.SnapshotNow(rec.Path, "scheduled");

        var w = Open(0, ServerSection.Backups, 980);
        var vm = Section<BackupsViewModel>(w);
        Assert.Equal(2, vm.Snapshots.Count);
        Shot.Save(w, "snapshots");

        vm.SnapshotNowCommand.Execute(null);
        for (var i = 0; i < 200 && vm.Snapshots.Count < 3; i++) { await Task.Delay(50); Avalonia.Threading.Dispatcher.UIThread.RunJobs(); }
        Assert.Equal(3, vm.Snapshots.Count);
        Assert.Equal(3, SnapshotManager.List(rec.Path).Count);
        w.Close();
    }

    [AvaloniaFact]
    public async Task NetworkTabShowsTunnelAndCrossplay()
    {
        using var t = Shot.Seed();
        var rec = AppServices.Store.All[1];     // Paper: can run Geyser
        Directory.CreateDirectory(Path.Combine(rec.Path, "plugins", "Geyser-Spigot"));
        File.WriteAllText(Path.Combine(rec.Path, "plugins", "Geyser-Spigot.jar"), "x");
        File.WriteAllText(Path.Combine(rec.Path, "plugins", "Geyser-Spigot", "config.yml"), "bedrock:\n  port: 19133\n");

        var w = Open(1, ServerSection.Network, 1500);
        var vm = Section<NetworkViewModel>(w);
        Assert.True(vm.XpOn); Assert.True(vm.XpFloodgateMissing); Assert.Equal(19133, vm.XpPort);
        Assert.True(vm.XpNeedsUpdate);                               // an old Geyser with no recorded build can't do Bedrock 26.60
        Assert.Contains("TCP", vm.XpUdpText); Assert.Contains("19133", vm.XpUdpText);
        Assert.True(vm.TunnelStopped);
        Shot.Save(w, "network-tunnel-off");

        if (!OperatingSystem.IsWindows())
        {
            var script = Path.Combine(t.Path, "bore.sh");
            File.WriteAllText(script, "#!/bin/sh\necho 'listening at bore.pub:41999' >&2\nsleep 30\n");
            File.SetUnixFileMode(script, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            var tm = TunnelManager.Shared;
            tm.ExecutableOverride = script;
            try
            {
                vm.StartTunnelCommand.Execute(null);
                for (var i = 0; i < 200 && !vm.TunnelHasAddress; i++) { await Task.Delay(50); Avalonia.Threading.Dispatcher.UIThread.RunJobs(); }
                Assert.Equal("bore.pub:41999", vm.TunnelAddress);
                Assert.Equal("bore.pub:41999", vm.Recommended);      // the tunnel address is what friends are told first
                Assert.Contains("Free tunnel", vm.RecommendedLabel);
                Shot.Save(w, "network-tunnel-on");
            }
            finally { tm.StopAll(); tm.ExecutableOverride = null; }
            Avalonia.Threading.Dispatcher.UIThread.RunJobs();
            Assert.True(vm.TunnelStopped);
        }
        w.Close();
    }

    [AvaloniaFact]
    public void NetworkTabOnVanillaExplainsCrossplayIsUnavailable()
    {
        using var t = Shot.Seed();
        AppServices.Store.Update(AppServices.Store.All[2].Also(r => r.ServerType = ServerType.Vanilla));
        var w = Open(2, ServerSection.Network, 1300);
        var vm = Section<NetworkViewModel>(w);
        Assert.True(vm.XpIncompatible); Assert.False(vm.XpOff);
        Shot.Save(w, "network-vanilla");
        w.Close();
    }

    [AvaloniaFact]
    public void PortRulesCardPicksPresetsWarnsAndSavesCustomOnes()
    {
        using var t = Shot.Seed();
        var w = Open(0, ServerSection.Network, 2300);
        var vm = Section<NetworkViewModel>(w).Ports;
        Assert.Contains(vm.Chips, c => c.Name == "FiveM");
        vm.Chips.First(c => c.Name == "FiveM").PickCommand.Execute(null);
        Assert.Single(vm.Rules); Assert.Equal("30120", vm.Rules[0].Port); Assert.Equal(2, vm.Commands.Count());
        vm.AddRuleCommand.Execute(null);
        vm.Rules[1].Port = "25575";
        Assert.Contains(vm.Issues, i => i.Contains("RCON"));
        vm.Rules[1].Port = "99999";
        Assert.Contains(vm.Issues, i => i.StartsWith("Fix:") && i.Contains("99999"));
        vm.Rules[1].Port = "30120"; vm.Rules[1].ProtocolIndex = 1;
        Assert.Contains(vm.Issues, i => i.Contains("UDP 30120") && i.Contains("listed twice"));
        w.Show();
        Shot.Save(w, "network-port-rules");
        w.Close();
    }

    [AvaloniaFact]
    public void SettingsShowsSnapshotScheduleAndSavesIt()
    {
        using var t = Shot.Seed();
        var w = Open(0, ServerSection.Settings, 1900);
        var vm = Section<ServerSettingsViewModel>(w);
        vm.SnapshotsOn = true; vm.SnapshotMins = 10; vm.SnapshotRecentHours = 12; vm.SnapshotDailyDays = 14;
        Assert.Contains("every 10 min", vm.SnapshotSummary);
        w.Show();
        foreach (var sv in Avalonia.VisualTree.VisualExtensions.GetVisualDescendants(w).OfType<Avalonia.Controls.ScrollViewer>()) sv.ScrollToEnd();
        Shot.Save(w, "settings-snapshots");
        vm.SaveCommand.Execute(null);
        var s = AppServices.Store.All[0].Schedule;
        Assert.Equal(10, s.SnapshotIntervalMins); Assert.Equal(12, s.SnapshotRecentHours); Assert.Equal(14, s.SnapshotDailyDays);
        w.Close();
    }

    [AvaloniaFact]
    public void WorldsTabOffersLevelDatEditing()
    {
        using var t = Shot.Seed();
        Populate(AppServices.Store.All[0].Path);
        var w = Open(0, ServerSection.Worlds);
        Assert.True(Section<WorldsViewModel>(w).Worlds.Single().HasLevelDat);
        Shot.Save(w, "worlds-leveldat");
        w.Close();
    }

    static string SampleLevelDat(TempDir t)
    {
        var data = new NbtCompound([
            new("LevelName", new NbtString("MCServ")), new("GameType", new NbtInt(0)), new("Difficulty", new NbtByte(1)), new("hardcore", new NbtByte(0)),
            new("RandomSeed", new NbtLong(-4172144997902289642)), new("SpawnX", new NbtInt(112)), new("Time", new NbtLong(6203511)), new("raining", new NbtByte(0)),
            new("allowCommands", new NbtByte(1)), new("Version", new NbtCompound([new("Name", new NbtString("26.2")), new("Id", new NbtInt(4900)), new("Snapshot", new NbtByte(0))])),
            new("GameRules", new NbtCompound([new("doDaylightCycle", new NbtString("true")), new("keepInventory", new NbtString("false")), new("playersSleepingPercentage", new NbtString("100"))])),
            new("spawn", new NbtIntArray([112, 72, 112])), new("DataPacks", new NbtCompound([new("Enabled", new NbtList(TagType.String, [new NbtString("vanilla"), new NbtString("fabric")]))])),
        ]);
        var path = t.Sub("world/level.dat");
        Nbt.Write(path, new NbtFile("", new NbtCompound([new("Data", data)]), true));
        return path;
    }

    [AvaloniaFact]
    public async Task NbtEditorEditsValidatesAndSaves()
    {
        using var t = Shot.Seed();
        var path = SampleLevelDat(t);
        var vm = new NbtEditorViewModel(path, "world/level.dat", serverRunning: false);
        var w = new NbtEditorWindow(vm);
        Shot.Save(w, "nbt-editor");

        Assert.True(vm.Loaded); Assert.False(vm.Dirty); Assert.False(vm.CanSave);
        NbtNodeViewModel Find(NbtNodeViewModel n, string key) => n.Key == key ? n : n.Children.Select(c => Find(c, key)).FirstOrDefault(x => x is not null)!;
        var root = vm.Roots[0];
        var name = Find(root, "LevelName"); var diff = Find(root, "Difficulty"); var seed = Find(root, "RandomSeed");

        Assert.Equal("-4172144997902289642", seed.Text);               // a 64-bit seed is shown exactly
        diff.Text = "abc";                                             // not a byte: flagged, not applied
        Assert.True(diff.Invalid); Assert.False(vm.Dirty);
        diff.Text = "300";                                             // out of range for a byte
        Assert.True(diff.Invalid);
        diff.Text = "2";
        Assert.False(diff.Invalid); Assert.True(vm.Dirty); Assert.True(vm.CanSave);
        diff.Text = "1";                                               // back to the original → nothing to save
        Assert.False(vm.Dirty);

        name.Text = "My Server 🌍";
        diff.Text = "3";
        Assert.True(vm.CanSave);
        Shot.Save(w, "nbt-editor-edited");
        vm.SaveCommand.Execute(null);
        for (var i = 0; i < 200 && vm.Dirty; i++) { await Task.Delay(25); Avalonia.Threading.Dispatcher.UIThread.RunJobs(); }
        Assert.False(vm.Dirty);

        var back = (NbtCompound)Nbt.Read(path).Root.Entries[0].Value;
        Assert.Equal("My Server 🌍", ((NbtString)back.Entries.First(e => e.Key == "LevelName").Value).Value);
        Assert.Equal(3, ((NbtByte)back.Entries.First(e => e.Key == "Difficulty").Value).Value);
        Assert.Equal(-4172144997902289642, ((NbtLong)back.Entries.First(e => e.Key == "RandomSeed").Value).Value);   // untouched
        Assert.True(File.Exists(path + ".craftpanel-bak"));
        w.Close();
    }

    [AvaloniaFact]
    public void NbtEditorRefusesToSaveWhileTheServerRunsAndReportsBrokenFiles()
    {
        using var t = Shot.Seed();
        var path = SampleLevelDat(t);
        var running = new NbtEditorViewModel(path, "world/level.dat", serverRunning: true);
        ((NbtNodeViewModel)running.Roots[0].Children[0].Children[0]).Text = "Renamed";
        Assert.True(running.Dirty); Assert.False(running.CanSave);
        var w = new NbtEditorWindow(running);
        Shot.Save(w, "nbt-editor-running");
        w.Close();

        var junk = t.Write("junk.dat", "not nbt at all");
        var broken = new NbtEditorViewModel(junk, "junk.dat", false);
        Assert.False(broken.Loaded); Assert.True(broken.HasError); Assert.Empty(broken.Roots);
        var w2 = new NbtEditorWindow(broken);
        Shot.Save(w2, "nbt-editor-broken");
        w2.Close();
    }
    [AvaloniaFact]
    public void BackupsTabShowsAnImportedBackupAndTheImportButton()
    {
        using var t = Shot.Seed();
        var rec = AppServices.Store.All[0];
        Populate(rec.Path);
        File.WriteAllText(Path.Combine(rec.Path, "server.properties"), "level-name=world\n");
        BackupManager.BackupNow(rec.Path, "mine, last week", "manual");
        // a friend's latest backup, brought over as a zip + json
        var friend = Path.Combine(t.Path, "friend"); Directory.CreateDirectory(Path.Combine(friend, "world"));
        File.WriteAllText(Path.Combine(friend, "server.properties"), "level-name=world\n"); File.WriteAllText(Path.Combine(friend, "world", "level.dat"), "theirs");
        var theirs = BackupManager.BackupNow(friend, "Sam's latest", "manual");
        var zip = Path.Combine(BackupManager.Root(friend), theirs.Id + ".zip");
        BackupManager.ImportBackup(rec.Path, zip, BackupManager.SiblingJson(zip));

        var w = Open(0, ServerSection.Backups, 980);
        var vm = Section<BackupsViewModel>(w);
        Assert.Contains(vm.Backups, b => b.IsImported && b.Title == "Sam's latest");
        Assert.True(vm.ImportCommand.CanExecute(null));
        Shot.Save(w, "backups-imported");
        w.Close();
    }

    [AvaloniaFact]
    public async Task ReportWindowSavesARedactedReportWithTheChosenServersConsole()
    {
        using var t = Shot.Seed();
        var outDir = Path.Combine(t.Path, "reports"); ReportBuilder.OutputFolderOverride = outDir;
        try
        {
            CraftPanel.App.Services.Palette.Dark.Apply(Avalonia.Application.Current!);
            var rec = AppServices.Store.All[0];
            var rt = AppServices.Processes.Runtime(rec.Id);
            rt.Push(CraftPanel.Core.Runtime.LogStream.Stdout, "[12:00:01] [Server thread/INFO]: Starting minecraft server");
            rt.Push(CraftPanel.Core.Runtime.LogStream.Stdout, "[12:00:02] [Server thread/INFO]: Steve joined from /8.8.8.8:5000");

            var vm = new ReportViewModel("System.InvalidOperationException: example error");
            vm.Description = "Start does nothing";
            vm.SelectedServer = rec.Name;
            var w = new ReportWindow(vm);
            Shot.Save(w, "report-window");
            vm.SaveCommand.Execute(null);
            for (var i = 0; i < 400 && !vm.HasSaved; i++) { await Task.Delay(50); Avalonia.Threading.Dispatcher.UIThread.RunJobs(); }
            Assert.True(vm.HasSaved);
            Assert.StartsWith(outDir, vm.SavedPath);
            using (var z = System.IO.Compression.ZipFile.OpenRead(vm.SavedPath))
            {
                var console = new StreamReader(z.GetEntry("console.txt")!.Open()).ReadToEnd();
                var report = new StreamReader(z.GetEntry("report.txt")!.Open()).ReadToEnd();
                Assert.Contains("Starting minecraft server", console); Assert.DoesNotContain("8.8.8.8", console);
                Assert.Contains("Start does nothing", report); Assert.Contains("example error", report);
            }
            Shot.Save(w, "report-window-saved");
            w.Close();
        }
        finally { ReportBuilder.OutputFolderOverride = null; }
    }

    static string FriendsWorld(TempDir t, string name, string version)
    {
        var w = Path.Combine(t.Path, "friend", name);
        Directory.CreateDirectory(Path.Combine(w, "region"));
        var root = new NbtCompound([new("Data", new NbtCompound([new("LevelName", new NbtString(name)), new("Version", new NbtCompound([new("Name", new NbtString(version))]))]))]);
        var raw = Nbt.Encode("", root);
        using var ms = new MemoryStream(); using (var gz = new System.IO.Compression.GZipStream(ms, System.IO.Compression.CompressionLevel.Fastest, true)) gz.Write(raw);
        File.WriteAllBytes(Path.Combine(w, "level.dat"), ms.ToArray());
        File.WriteAllText(Path.Combine(w, "region", "r.0.0.mca"), "THEIRS");
        return w;
    }

    [AvaloniaFact]
    public async Task DroppingAWorldFolderAddsItAndOffersToSwitch()
    {
        using var t = Shot.Seed();
        var dialogs = new FakeDialogs();
        var rec = AppServices.Store.All[1];                            // Paper 1.21.1
        File.WriteAllText(Path.Combine(rec.Path, "server.properties"), "level-name=world\n");
        Directory.CreateDirectory(Path.Combine(rec.Path, "world")); File.WriteAllText(Path.Combine(rec.Path, "world", "level.dat"), "x");
        var src = FriendsWorld(t, "Friend Survival", "1.21.1");

        var w = Open(1, ServerSection.Worlds);
        var vm = Section<WorldsViewModel>(w);
        CraftPanel.App.Services.Dialogs.Current = dialogs;            // after the window, which installs its own
        dialogs.Confirms.Enqueue(true);                               // add it
        dialogs.Confirms.Enqueue(true);                               // use it now
        await vm.ImportDroppedAsync([src]);
        Assert.Equal("THEIRS", File.ReadAllText(Path.Combine(rec.Path, "Friend Survival", "region", "r.0.0.mca")));
        Assert.Contains("Friend Survival", dialogs.Asked[0].Message); Assert.Contains("1.21.1", dialogs.Asked[0].Message);
        Assert.Contains("level-name=Friend Survival", File.ReadAllText(Path.Combine(rec.Path, "server.properties")));
        Assert.Contains(vm.Worlds, x => x.Name == "Friend Survival" && x.Active);
        Assert.Contains(vm.Worlds, x => x.Name == "world" && !x.Active);               // the old world is still there
        Assert.Contains("will load the next time", vm.Status);
        Shot.Save(w, "worlds-imported");
        w.Close();
    }

    [AvaloniaFact]
    public async Task ANewerWorldIsWarnedAboutAndCancellingCopiesNothing()
    {
        using var t = Shot.Seed();
        var dialogs = new FakeDialogs();
        var rec = AppServices.Store.All[1];                            // Paper 1.21.1
        var src = FriendsWorld(t, "FutureWorld", "26.2");
        var w = Open(1, ServerSection.Worlds);
        var vm = Section<WorldsViewModel>(w);
        CraftPanel.App.Services.Dialogs.Current = dialogs;

        dialogs.Confirms.Enqueue(false);
        await vm.ImportDroppedAsync([src]);
        Assert.Contains("newer", dialogs.Asked[0].Message); Assert.Contains("Add this world anyway?", dialogs.Asked[0].Title);
        Assert.False(Directory.Exists(Path.Combine(rec.Path, "FutureWorld")));

        await vm.ImportDroppedAsync([src, src]);                      // two at once
        Assert.Contains("One world at a time", vm.Status);
        await vm.ImportDroppedAsync([Path.Combine(t.Path, "nothing-here")]);
        Assert.Contains("Pick a world folder", vm.Status);
        w.Close();
    }

    [AvaloniaFact]
    public async Task ExportSavesTheActiveWorldAsAZip()
    {
        using var t = Shot.Seed();
        var dialogs = new FakeDialogs();
        var outDir = Path.Combine(t.Path, "exports"); ReportBuilder.OutputFolderOverride = outDir;
        try
        {
            var rec = AppServices.Store.All[1];
            File.WriteAllText(Path.Combine(rec.Path, "server.properties"), "level-name=Survival\n");
            Directory.CreateDirectory(Path.Combine(rec.Path, "Survival")); File.WriteAllText(Path.Combine(rec.Path, "Survival", "level.dat"), "x");
            var w = Open(1, ServerSection.Worlds);
            var vm = Section<WorldsViewModel>(w);
            CraftPanel.App.Services.Dialogs.Current = dialogs;
            vm.ExportCommand.Execute(null);
            for (var i = 0; i < 200 && dialogs.OpenedFolders.Count == 0; i++) { await Task.Delay(50); Avalonia.Threading.Dispatcher.UIThread.RunJobs(); }
            Assert.Single(Directory.GetFiles(outDir, "Survival-*.zip"));
            Assert.Equal([outDir], dialogs.OpenedFolders);
            w.Close();
        }
        finally { ReportBuilder.OutputFolderOverride = null; }
    }

    [AvaloniaFact]
    public void HelpButtonOpensHelpForTheCurrentPage()
    {
        using var t = Shot.Seed();
        var w = Open(0, ServerSection.Worlds);
        var main = (MainViewModel)w.DataContext!;
        var dialogs = new FakeDialogs(); CraftPanel.App.Services.Dialogs.Current = dialogs;

        main.ShowHelpCommand.Execute(null);
        Assert.Equal(("server.worlds", false), dialogs.HelpShown[^1]);
        main.Open(AppServices.Store.All[0].Id, ServerSection.Addons); main.ShowHelpCommand.Execute(null);
        Assert.Equal("server.addons", dialogs.HelpShown[^1].Page);
        foreach (var (section, page) in new[] { (ServerSection.Console, "server.console"), (ServerSection.Network, "server.network"), (ServerSection.Backups, "server.backups"), (ServerSection.Files, "server.files"), (ServerSection.Settings, "server.settings") })
        {
            ((ServerDetailViewModel)main.Content).Select(section);
            Assert.Equal(page, main.CurrentHelpPage());
        }
        main.ShowSettings(); ((AppSettingsViewModel)main.Content).Select(SettingsTab.Java);
        Assert.Equal("settings.java", main.CurrentHelpPage());
        main.ShowOverview();
        Assert.Equal("overview", main.CurrentHelpPage());
        w.Close();
    }

    [AvaloniaFact]
    public void ButtonsInsideGuidesTakeYouWhereTheyPoint()
    {
        using var t = Shot.Seed();
        var w = Open(0, ServerSection.Console);
        var main = (MainViewModel)w.DataContext!;
        var dialogs = new FakeDialogs(); CraftPanel.App.Services.Dialogs.Current = dialogs;

        main.RunHelpAction(new HelpAction("Open Worlds", HelpActionKind.Section, "Worlds"));
        Assert.Equal(ServerSection.Worlds, ((ServerDetailViewModel)main.Content).Current);
        main.RunHelpAction(new HelpAction("Open Java", HelpActionKind.SettingsTab, "Java"));
        Assert.Equal(SettingsTab.Java, ((AppSettingsViewModel)main.Content).Tab);
        main.RunHelpAction(new HelpAction("Copy", HelpActionKind.Copy, "op YourName"));
        Assert.Equal(["op YourName"], dialogs.Copied);
        main.RunHelpAction(new HelpAction("Overview", HelpActionKind.Overview));
        Assert.True(main.OnOverview);
        w.Close();
    }

    [AvaloniaFact]
    public void HelpWindowShowsThisPageTheLibraryAndTheTour()
    {
        using var t = Shot.Seed();
        CraftPanel.App.Services.Palette.Dark.Apply(Avalonia.Application.Current!);
        var ran = new List<HelpAction>();
        var vm = new HelpViewModel("server.worlds", false, ran.Add);
        var w = new HelpWindow(vm);
        Assert.True(vm.IsPage); Assert.Equal("add-world", vm.Selected!.Id); Assert.True(vm.Steps.Count >= 3);
        Shot.Save(w, "help-page");

        vm.RunActionCommand.Execute(vm.Steps.First(s => s.HasAction).Action);
        Assert.Single(ran);

        vm.ShowLibraryCommand.Execute(null);
        vm.Query = "make myself op";
        Assert.Equal("make-op", vm.Topics[0].Id);
        Shot.Save(w, "help-library");
        vm.Query = "zzzz";
        Assert.True(vm.NoTopics);

        vm.ShowTourCommand.Execute(null);
        Assert.True(vm.IsTour); Assert.Equal("Step 1 of 11", vm.TourProgress);
        vm.NextCommand.Execute(null); vm.NextCommand.Execute(null);
        Assert.Equal("Step 3 of 11", vm.TourProgress); Assert.True(vm.BackCommand.CanExecute(null));
        Shot.Save(w, "help-tour");
        for (var i = 0; i < 20; i++) vm.NextCommand.Execute(null);
        w.Close();

        var empty = new HelpViewModel("settings.account", false, _ => { });          // a page always has tips; but an unknown page falls back to the library
        var unknown = new HelpViewModel("nonsense", false, _ => { });
        Assert.True(unknown.IsLibrary);
    }

    [AvaloniaFact]
    public async Task LightModeSettingPersistsAndLowSpecPresetAsksThenApplies()
    {
        using var t = Shot.Seed();
        var w = Open(0, ServerSection.Settings, 1100);
        var main = (MainViewModel)w.DataContext!;
        var dialogs = new FakeDialogs(); CraftPanel.App.Services.Dialogs.Current = dialogs;
        var rec = AppServices.Store.All[0];
        File.WriteAllText(Path.Combine(rec.Path, "server.properties"), "view-distance=14\nmotd=Hi\n");
        var vm = Section<ServerSettingsViewModel>(w);
        vm.DiscardCommand.Execute(null);                                   // re-read the file we just wrote

        dialogs.Confirms.Enqueue(false);
        await RunCmd(vm.LowSpecCommand);
        Assert.Contains("view-distance: 14 → 6", dialogs.Asked[^1].Message);
        Assert.Equal(14, Properties.Load(rec.Path).GetInt("view-distance", 0));              // declined: untouched
        dialogs.Confirms.Enqueue(true);
        await RunCmd(vm.LowSpecCommand);
        Assert.Equal(6, Properties.Load(rec.Path).GetInt("view-distance", 0));
        Assert.Equal(4, Properties.Load(rec.Path).GetInt("simulation-distance", 0));
        Assert.Equal(6, vm.ViewDistance);                                                     // the form shows the new value

        main.ShowSettings(); var app = (AppSettingsViewModel)main.Content; app.Select(SettingsTab.General);
        Assert.Equal(0, app.LightIndex);
        app.LightIndex = 1;
        Assert.Equal("on", AppServices.Settings.LightMode);
        Assert.Equal(1, AppSettings.Load(Path.Combine(t.Path, "settings.json")).LightMode == "on" ? 1 : 0);   // saved to disk
        Assert.Contains("next time OMNIServers starts", app.LightStatus);
        Shot.Save(w, "settings-performance");
        w.Close();
    }

    [AvaloniaFact]
    public void ModsTabSurvivesTheSameFileListedTwiceInTheAddOnList()
    {
        using var t = Shot.Seed();
        var rec = AppServices.Store.All[0];                              // Fabric: has a Mods tab
        Directory.CreateDirectory(Path.Combine(rec.Path, "mods"));
        File.WriteAllText(Path.Combine(rec.Path, "mods", "fabric-api-0.161.0+26.2.jar"), "x");
        var entry = "{\"project_id\":\"P1\",\"slug\":\"fabric-api\",\"title\":\"Fabric API\",\"filename\":\"fabric-api-0.161.0+26.2.jar\",\"version_id\":\"v\",\"version_number\":\"1\",\"dependency\":false}";
        File.WriteAllText(Path.Combine(rec.Path, ".craftpanel-modrinth.json"), "[" + entry + "," + entry.Replace("P1", "P2") + "]");   // what the real MCServ had
        var w = Open(0, ServerSection.Mods);                              // used to crash here
        var vm = Section<ModsViewModel>(w);
        Assert.Single(vm.Mods); Assert.Equal("Fabric API", vm.Mods[0].ManagedTitle);
        w.Close();
    }

    [AvaloniaFact]
    public async Task NetworkTabSharesAServerShowsWhoHostsItAndBuildsAnInvite()
    {
        using var t = Shot.Seed();
        // a port nothing listens on, so a real Minecraft server on this machine can't answer the "is it running?" check
        var free = System.Net.Sockets.TcpListener.Create(0); free.Start(); var freePort = ((System.Net.IPEndPoint)free.LocalEndpoint).Port; free.Stop();
        var props = Path.Combine(AppServices.Store.All[1].Path, "server.properties");
        File.WriteAllText(props, File.Exists(props) ? System.Text.RegularExpressions.Regex.Replace(File.ReadAllText(props), "(?m)^server-port=.*$", "").TrimEnd() + $"\nserver-port={freePort}\n" : $"server-port={freePort}\n");
        var w = Open(1, ServerSection.Network, 1700);
        var vm = Section<NetworkViewModel>(w);
        var dialogs = new FakeDialogs(); CraftPanel.App.Services.Dialogs.Current = dialogs;
        var rec = AppServices.Store.All[1];
        Assert.True(vm.Share.NotShared);

        vm.Share.ShareCommand.Execute(null);
        Assert.True(vm.Share.IsShared); Assert.Matches("^[A-Z0-9]{4}-[A-Z0-9]{4}$", vm.Share.Code);
        Assert.Contains("Free", vm.Share.StatusText);
        Assert.True(File.Exists(Path.Combine(rec.Path, "craftpanel-share.json")));

        // another PC takes its turn
        File.WriteAllText(Path.Combine(rec.Path, "craftpanel-lease.json"), "{\"holder\":\"OTHER\",\"hostname\":\"SCHOOL-PC-12\",\"claimed_at\":1,\"expires_at\":" + (DateTimeOffset.UtcNow.ToUnixTimeSeconds() + 300) + "}");
        vm.Share.RefreshCommand.Execute(null);
        Assert.Contains("SCHOOL-PC-12", vm.Share.StatusText);
        Shot.Save(w, "network-share");

        vm.CopyInviteCommand.Execute(null);
        Assert.Contains("Survival SMP", dialogs.Copied[^1]); Assert.Contains("1.21.1", dialogs.Copied[^1]); Assert.Contains("Multiplayer", dialogs.Copied[^1]);

        await RunCmd(vm.TestServerCommand);
        Assert.Contains("Nothing is answering", vm.TestResult);                 // the server isn't running

        dialogs.Confirms.Enqueue(true);
        await RunCmd(vm.Share.StopSharingCommand);
        Assert.True(vm.Share.IsShared);                                          // refused: the other PC is running it
        Assert.Contains("in use on another PC", vm.Share.Error);
        File.Delete(Path.Combine(rec.Path, "craftpanel-lease.json"));
        dialogs.Confirms.Enqueue(true);
        await RunCmd(vm.Share.StopSharingCommand);
        Assert.True(vm.Share.NotShared);
        w.Close();
    }

    [AvaloniaFact]
    public void PerformanceTabShowsTilesAndGraphAndSwitchesRange()
    {
        using var t = Shot.Seed();
        var rec = AppServices.Store.All[0];
        var w = Open(0, ServerSection.Performance, 900);
        var vm = Section<PerformanceViewModel>(w);
        Assert.True(vm.NoData);
        Shot.Save(w, "performance-empty");

        var now = DateTime.UtcNow;
        AppServices.Metrics.Inject(rec.Id, Enumerable.Range(0, 120).Select(i => new CraftPanel.Core.Runtime.MetricSample(now.AddSeconds(-(120 - i) * 3), 1500 + i * 8, 10 + 25 * Math.Abs(Math.Sin(i / 9.0)))));
        vm.Refresh();
        Assert.True(vm.HasData);
        Assert.Equal(4, vm.Ranges.Count(r => !r.IsActive) );
        vm.Ranges[0].SelectCommand.Execute(null);       // 1m window
        Assert.True(vm.Cpu.Count < 30 && vm.Cpu.Count >= 2);
        vm.Ranges[2].SelectCommand.Execute(null);       // 30m window holds all 120
        Assert.Equal(120, vm.Cpu.Count);
        Shot.Save(w, "performance-graph");
        w.Close();
    }
}

static class Ext { public static T Also<T>(this T x, Action<T> f) { f(x); return x; } 
}
