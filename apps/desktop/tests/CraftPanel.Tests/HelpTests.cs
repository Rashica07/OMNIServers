using CraftPanel.Core.Help;
using Xunit;

namespace CraftPanel.Tests;

public class HelpTests
{
    static readonly string[] Sections = ["Console", "Chat", "Network", "Players", "Map", "Settings", "Addons", "Mods", "Worlds", "Backups", "Files"];
    static readonly string[] SettingsTabs = ["General", "Account", "Java", "Backups", "Diagnostics", "About"];

    [Fact]
    public void EveryPageOfTheAppHasAtLeastOneTopic()
    {
        foreach (var page in HelpPages.All.Keys)
            Assert.True(HelpLibrary.ForPage(page).Count > 0, $"no help for page '{page}'");
    }

    [Fact]
    public void EveryServerTabAndSettingsTabMapsToAHelpPage()
    {
        foreach (var s in Sections) Assert.True(HelpPages.All.ContainsKey(HelpPages.ForServerSection(s)), s);
        foreach (var t in SettingsTabs) Assert.True(HelpPages.All.ContainsKey(HelpPages.ForSettingsTab(t)), t);
        Assert.Equal("server.addons", HelpPages.ForServerSection("Addons"));
    }

    [Fact]
    public void TopicsAreWellFormedAndLinkOnlyToRealPagesAndActions()
    {
        Assert.Equal(HelpLibrary.All.Count, HelpLibrary.All.Select(t => t.Id).Distinct().Count());
        foreach (var t in HelpLibrary.All)
        {
            Assert.False(string.IsNullOrWhiteSpace(t.Title)); Assert.False(string.IsNullOrWhiteSpace(t.Summary));
            Assert.NotEmpty(t.Steps); Assert.NotEmpty(t.Pages); Assert.NotEmpty(t.Keywords);
            foreach (var p in t.Pages) Assert.True(HelpPages.All.ContainsKey(p), $"{t.Id}: unknown page {p}");
            foreach (var s in t.Steps) { Assert.False(string.IsNullOrWhiteSpace(s.Text), t.Id); if (s.Action is { } a) CheckAction(a, t.Id); }
        }
    }

    static void CheckAction(HelpAction a, string where)
    {
        Assert.False(string.IsNullOrWhiteSpace(a.Label), where);
        switch (a.Kind)
        {
            case HelpActionKind.Section: Assert.Contains(a.Arg, Sections); break;
            case HelpActionKind.SettingsTab: Assert.Contains(a.Arg, SettingsTabs); break;
            case HelpActionKind.Copy: Assert.False(string.IsNullOrWhiteSpace(a.Arg), where); break;
        }
    }

    [Fact]
    public void TheTourCoversTheBasicsInOrderWithValidActions()
    {
        var tour = HelpContent.Tour;
        Assert.InRange(tour.Count, 8, 14);
        Assert.StartsWith("Welcome", tour[0].Title);
        foreach (var s in tour) { Assert.False(string.IsNullOrWhiteSpace(s.Title)); Assert.False(string.IsNullOrWhiteSpace(s.Text)); if (s.Action is { } a) CheckAction(a, s.Title); }
        var all = string.Join(' ', tour.Select(s => s.Title + s.Text)).ToLowerInvariant();
        foreach (var must in new[] { "new server", "start", "join", "op", "world", "backup", "report" }) Assert.Contains(must, all);
    }

    [Theory]
    [InlineData("op", "make-op")]
    [InlineData("operator", "make-op")]
    [InlineData("drag", "add-world")]
    [InlineData("world folder", "add-world")]
    [InlineData("single player", "add-world")]
    [InlineData("wifi", "join-lan")]
    [InlineData("tunnel", "tunnel")]
    [InlineData("phone", "bedrock")]
    [InlineData("friend's backup", "import-backup")]
    [InlineData("school", "school-pc")]
    [InlineData("lag", "low-spec")]
    [InlineData("crash report", "report-problem")]
    public void SearchFindsTheRightHowTo(string query, string expectedFirstOrNear)
    {
        var hits = HelpLibrary.Search(query);
        Assert.Contains(hits.Take(3), t => t.Id == expectedFirstOrNear);
    }

    [Fact]
    public void SearchRequiresEveryWordAndEmptyReturnsEverything()
    {
        Assert.Empty(HelpLibrary.Search("zzzqqq"));
        Assert.Empty(HelpLibrary.Search("whitelist zzzqqq"));
        Assert.Equal(HelpLibrary.All.Count, HelpLibrary.Search("").Count);
        Assert.Equal(HelpLibrary.All.Count, HelpLibrary.Search(null).Count);
        Assert.Equal("whitelist", HelpLibrary.Search("WHITELIST").First().Id);
    }

    [Fact]
    public void PageHelpIsTheMostRelevantFirst()
    {
        Assert.Equal("add-world", HelpLibrary.ForPage(HelpPages.ServerWorlds)[0].Id);
        Assert.Equal("import-backup", HelpLibrary.ForPage(HelpPages.ServerBackups).First(t => t.Id.Contains("import")).Id);
        Assert.Equal("create-server", HelpLibrary.ForPage(HelpPages.Overview)[0].Id);
    }

    [Fact]
    public void TheHowToLibraryIsSubstantial()
    {
        Assert.True(HelpLibrary.All.Count >= 30);
        foreach (var must in new[] { "make-op", "whitelist", "add-world", "export-world", "import-backup", "restore-backup", "join-internet", "firewall", "report-problem", "school-pc" })
            Assert.NotNull(HelpLibrary.Find(must));
    }
}
