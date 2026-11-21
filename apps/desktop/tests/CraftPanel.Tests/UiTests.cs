using Avalonia.Headless.XUnit;
using CraftPanel.App.Services;
using CraftPanel.App.ViewModels;
using CraftPanel.App.Views;
using CraftPanel.Core.Adapters;
using CraftPanel.Core.Runtime;
using Xunit;

namespace CraftPanel.Tests;

public class UiTests
{
    [AvaloniaFact]
    public void MainWindowOverviewRenders()
    {
        using var t = Shot.Seed();
        CraftPanel.App.Services.Palette.Dark.Apply(Avalonia.Application.Current!);
        var first = AppServices.Store.All[0];
        var rt = AppServices.Processes.Runtime(first.Id);
        rt.ForceStateForTest(ServerStatus.Running);
        rt.Push(LogStream.Stdout, "[12:00:01] [Server thread/INFO]: Steve joined the game");
        var w = new MainWindow { Width = 1180, Height = 780 };
        var path = Shot.Save(w, "main-overview");
        Assert.True(new FileInfo(path).Length > 5000);
        var vm = (MainViewModel)w.DataContext!;
        Assert.Equal(3, vm.Servers.Count);
        Assert.Equal(1, vm.RunningCount);
        w.Close();
    }

    [AvaloniaFact]
    public void SidebarShrinksToIconRailAndBack()
    {
        using var t = Shot.Seed();
        CraftPanel.App.Services.Palette.Dark.Apply(Avalonia.Application.Current!);
        var w = new MainWindow { Width = 1180, Height = 780 };
        var vm = (MainViewModel)w.DataContext!;
        vm.ToggleSidebarCommand.Execute(null);
        Assert.True(vm.SidebarCollapsed);
        Shot.Save(w, "main-rail");
        vm.ToggleSidebarCommand.Execute(null);
        Assert.False(vm.SidebarCollapsed);
        w.Close();
    }

    [AvaloniaFact]
    public void FirstRunWelcomeOffersOneClickServer()
    {
        using var t = Shot.Seed(withServers: false);
        CraftPanel.App.Services.Palette.Dark.Apply(Avalonia.Application.Current!);
        var w = new MainWindow { Width = 1180, Height = 780 };
        var vm = (MainViewModel)w.DataContext!;
        Assert.True(vm.Overview.Empty);
        Assert.True(vm.Overview.QuickIdle);
        Assert.True(vm.Overview.QuickCreateCommand.CanExecute(null));
        Shot.Save(w, "first-run-welcome");
        w.Close();
    }

    static MainWindow OpenServer(int index, Action<CraftPanel.Core.Runtime.ServerRuntime>? prep = null, ServerSection? section = null)
    {
        CraftPanel.App.Services.Palette.Dark.Apply(Avalonia.Application.Current!);
        var rec = AppServices.Store.All[index];
        var rt = AppServices.Processes.Runtime(rec.Id);
        prep?.Invoke(rt);
        var w = new MainWindow { Width = 1180, Height = 780 };
        ((MainViewModel)w.DataContext!).Open(rec.Id, section);
        return w;
    }

    [AvaloniaFact]
    public void ConsoleRenders()
    {
        using var t = Shot.Seed();
        var w = OpenServer(0, rt =>
        {
            rt.ForceStateForTest(ServerStatus.Running);
            rt.Push(LogStream.System, "Launched pid 4242: java -Xms1024M -Xmx4096M -jar fabric-server-launch.jar nogui");
            rt.Push(LogStream.Stdout, "[12:00:00] [main/INFO]: Starting minecraft server version 26.2");
            rt.Push(LogStream.Stdout, "[12:00:03] [Server thread/WARN]: Can't keep up! Is the server overloaded? Running 2100ms behind");
            rt.Push(LogStream.Stderr, "[12:00:04] [Server thread/ERROR]: Something went wrong");
            rt.Push(LogStream.Stdout, "[12:00:05] [Server thread/INFO]: Done (4.2s)! For help, type \"help\"");
            rt.Push(LogStream.Stdout, "[12:00:09] [Server thread/INFO]: Steve joined the game");
            rt.Push(LogStream.Stdout, "[12:00:10] [Server thread/INFO]: <Steve> hello");
            rt.Push(LogStream.System, "> list");
        });
        Shot.Save(w, "console");
        var vm = (MainViewModel)w.DataContext!;
        var detail = Assert.IsType<ServerDetailViewModel>(vm.Content);
        var console = Assert.IsType<ConsoleViewModel>(detail.Section);
        Assert.Equal(8, console.Visible().Count());
        console.Filter = "Steve";
        Assert.Equal(2, console.Visible().Count());
        w.Close();
    }

    [AvaloniaFact]
    public void ChatRenders()
    {
        using var t = Shot.Seed();
        var w = OpenServer(0, rt =>
        {
            rt.ForceStateForTest(ServerStatus.Running);
            foreach (var l in new[] { "Steve joined the game", "Alex joined the game", "<Steve> anyone found diamonds yet?", "<Alex> 3 so far, meet me at spawn",
                "Steve has made the advancement [Diamonds!]", "[Server] backup in 5 minutes", ".BedrockBob joined the game", "<.BedrockBob> hi from my phone" })
                rt.Push(LogStream.Stdout, "[12:00:00] [Server thread/INFO]: " + l);
            rt.AddChat(ChatKind.Mine, "Host", "welcome Bob!");
        }, ServerSection.Chat);
        Shot.Save(w, "chat");
        var vm = (MainViewModel)w.DataContext!;
        var chat = Assert.IsType<ChatViewModel>(((ServerDetailViewModel)vm.Content).Section);
        Assert.Equal(9, chat.Messages.Count);
        Assert.Equal(3, chat.Online.Count);
        chat.Draft = "hello from the test";
        Assert.True(chat.SendCommand.CanExecute(null));
        w.Close();
    }

    [AvaloniaFact]
    public void SettingsRendersAndSaves()
    {
        using var t = Shot.Seed();
        var w = OpenServer(0, section: ServerSection.Settings);
        var vm = (MainViewModel)w.DataContext!;
        var sv = Assert.IsType<ServerSettingsViewModel>(((ServerDetailViewModel)vm.Content).Section);
        sv.Name = "MCServ renamed"; sv.MaxPlayers = 12; sv.Motd = "Hello from tests"; sv.RamMB = 5120;
        Assert.True(sv.Dirty);
        Shot.Save(w, "settings");
        sv.SaveCommand.Execute(null);
        Assert.False(sv.Dirty);
        var rec = AppServices.Store.All[0];
        Assert.Equal("MCServ renamed", rec.Name); Assert.Equal(5120u, rec.RamMB);
        var p = CraftPanel.Core.Properties.Load(rec.Path);
        Assert.Equal("12", p.Get("max-players")); Assert.Equal("Hello from tests", p.Get("motd")); Assert.Equal("true", p.Get("online-mode"));
        Assert.Equal("MCServ renamed", vm.Servers[0].Name);
        w.Close();
    }

    [AvaloniaTheory]
    [InlineData(ServerSection.Players)]
    [InlineData(ServerSection.Backups)]
    [InlineData(ServerSection.Network)]
    [InlineData(ServerSection.Map)]
    [InlineData(ServerSection.Mods)]
    [InlineData(ServerSection.Worlds)]
    [InlineData(ServerSection.Files)]
    public void SectionRenders(ServerSection section)
    {
        using var t = Shot.Seed();
        var rec = AppServices.Store.All[0];
        Directory.CreateDirectory(Path.Combine(rec.Path, "world")); File.WriteAllText(Path.Combine(rec.Path, "world", "level.dat"), "x");
        Directory.CreateDirectory(Path.Combine(rec.Path, "mods")); File.WriteAllText(Path.Combine(rec.Path, "mods", "lithium-fabric-0.14.jar"), new string('x', 400_000)); File.WriteAllText(Path.Combine(rec.Path, "mods", "sodium.jar.disabled"), "x");
        File.WriteAllText(Path.Combine(rec.Path, "ops.json"), "[{\"uuid\":\"1\",\"name\":\"Steve\",\"level\":4}]");
        File.WriteAllText(Path.Combine(rec.Path, "whitelist.json"), "[{\"uuid\":\"2\",\"name\":\"Alex\"},{\"uuid\":\"3\",\"name\":\"Bob\"}]");
        File.WriteAllText(Path.Combine(rec.Path, "banned-players.json"), "[{\"uuid\":\"4\",\"name\":\"Griefer\",\"reason\":\"griefing\"}]");
        CraftPanel.Core.Backups.BackupManager.BackupNow(rec.Path, "before the update", "manual");
        var w = OpenServer(0, rt => rt.ForceStateForTest(ServerStatus.Running), section);
        var path = Shot.Save(w, "section-" + section.ToString().ToLowerInvariant());
        Assert.True(new FileInfo(path).Length > 5000);
        w.Close();
    }

    [AvaloniaTheory]
    [InlineData(SettingsTab.General)] [InlineData(SettingsTab.Account)] [InlineData(SettingsTab.Java)]
    [InlineData(SettingsTab.Backups)] [InlineData(SettingsTab.Diagnostics)] [InlineData(SettingsTab.About)]
    public void AppSettingsTabRenders(SettingsTab tab)
    {
        using var t = Shot.Seed();
        CraftPanel.App.Services.Palette.Dark.Apply(Avalonia.Application.Current!);
        var w = new MainWindow { Width = 1180, Height = 780 };
        var vm = (MainViewModel)w.DataContext!;
        vm.ShowSettings();
        ((AppSettingsViewModel)vm.Content).Select(tab);
        Shot.Save(w, "settings-tab-" + tab.ToString().ToLowerInvariant());
        w.Close();
    }

    [AvaloniaTheory]
    [InlineData(WizardMode.Custom)] [InlineData(WizardMode.QuickStart)]
    public void WizardRenders(WizardMode mode)
    {
        using var t = Shot.Seed();
        CraftPanel.App.Services.Palette.Dark.Apply(Avalonia.Application.Current!);
        var vm = new CreateWizardViewModel(mode);
        var w = new CraftPanel.App.Views.CreateWizardWindow(vm);
        Shot.Save(w, "wizard-" + mode.ToString().ToLowerInvariant() + "-1");
        if (mode == WizardMode.QuickStart) { vm.PickTemplateCommand.Execute(CreateWizardViewModel.Templates[1]); vm.NextTemplateCommand.Execute(null); }
        else { vm.PickLoaderCommand.Execute(CreateWizardViewModel.LoaderChoices[1]); }
        Shot.Save(w, "wizard-" + mode.ToString().ToLowerInvariant() + "-2");
        w.Close();
    }

    [AvaloniaFact]
    public void GameCardsSkipVersionStepAndHideJavaSettings()
    {
        using var t = Shot.Seed();
        CraftPanel.App.Services.Palette.Dark.Apply(Avalonia.Application.Current!);
        var vm = new CreateWizardViewModel(WizardMode.Custom);
        var w = new CraftPanel.App.Views.CreateWizardWindow(vm);
        Shot.Save(w, "wizard-games-1");
        var fivem = CreateWizardViewModel.LoaderChoices.First(c => c.Game == CraftPanel.Core.ServerType.FiveM);
        vm.PickLoaderCommand.Execute(fivem);
        Assert.Equal(WizardStep.Details, vm.Step);
        Assert.True(vm.IsGameServer); Assert.False(vm.ShowWorldSettings); Assert.Equal("Set up your FiveM server", vm.StepTitle); Assert.Equal("My FiveM Server", vm.Name);
        Shot.Save(w, "wizard-games-2");
        vm.BackCommand.Execute(null);
        Assert.Equal(WizardStep.Loader, vm.Step); Assert.False(vm.IsGameServer);
        w.Close();
    }

    [AvaloniaTheory]
    [InlineData("light")] [InlineData("midnight")] [InlineData("sunset")]
    public void ThemesRender(string theme)
    {
        using var t = Shot.Seed();
        var w = OpenServer(0, rt => { rt.ForceStateForTest(ServerStatus.Running); rt.Push(LogStream.Stdout, "[12:00:05] [Server thread/INFO]: Done (4.2s)! For help, type \"help\""); });
        CraftPanel.App.Services.Palette.ByName(theme).Apply(Avalonia.Application.Current!);
        Shot.Save(w, "theme-" + theme);
        w.Close();
        CraftPanel.App.Services.Palette.Dark.Apply(Avalonia.Application.Current!);
    }
}
