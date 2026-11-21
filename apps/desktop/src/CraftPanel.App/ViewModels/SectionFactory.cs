namespace CraftPanel.App.ViewModels;

public sealed class PlaceholderViewModel(string title) : ViewModelBase
{
    public string Title { get; } = title;
}

public static class SectionFactory
{
    public static ViewModelBase Create(ServerSection s, ServerItemViewModel server, ServerDetailViewModel detail) => s switch
    {
        ServerSection.Performance => new PerformanceViewModel(server),
        ServerSection.Console => new ConsoleViewModel(server),
        ServerSection.Chat => new ChatViewModel(server),
        ServerSection.Players => new PlayersViewModel(server),
        ServerSection.Backups => new BackupsViewModel(server),
        ServerSection.Network => new NetworkViewModel(server),
        ServerSection.Map => new MapViewModel(server),
        ServerSection.Addons => new AddonsViewModel(server),
        ServerSection.Mods => new ModsViewModel(server),
        ServerSection.Files => new FilesViewModel(server),
        ServerSection.Worlds => new WorldsViewModel(server),
        ServerSection.Settings => new ServerSettingsViewModel(server, detail),
        _ => new PlaceholderViewModel(s.Label()),
    };
}
