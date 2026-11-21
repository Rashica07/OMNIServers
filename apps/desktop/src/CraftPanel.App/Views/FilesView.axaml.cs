using Avalonia.Controls;
using Avalonia.Input;
using CraftPanel.App.ViewModels;

namespace CraftPanel.App.Views;

public partial class FilesView : UserControl
{
    public FilesView() => InitializeComponent();

    void OnDoubleTapped(object? sender, TappedEventArgs e)
    {
        if (DataContext is FilesViewModel vm && vm.Selected is { } row) vm.OpenCommand.Execute(row);
    }
}
