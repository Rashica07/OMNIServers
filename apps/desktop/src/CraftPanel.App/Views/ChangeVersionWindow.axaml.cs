using Avalonia.Controls;
using CraftPanel.App.ViewModels;

namespace CraftPanel.App.Views;

public partial class ChangeVersionWindow : Window
{
    public ChangeVersionWindow() => InitializeComponent();

    public ChangeVersionWindow(ChangeVersionViewModel vm) : this()
    {
        DataContext = vm;
        vm.RequestClose += () => Avalonia.Threading.Dispatcher.UIThread.Post(Close);
    }
}
