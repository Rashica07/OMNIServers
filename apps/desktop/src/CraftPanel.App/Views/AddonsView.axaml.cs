using Avalonia.Controls;
using Avalonia.Input;
using CraftPanel.App.ViewModels;

namespace CraftPanel.App.Views;

public partial class AddonsView : UserControl
{
    public AddonsView()
    {
        InitializeComponent();
        SearchBox.KeyDown += (_, e) => { if (e.Key == Key.Enter && DataContext is AddonsViewModel vm) { vm.SearchCommand.Execute(null); e.Handled = true; } };
    }
}
