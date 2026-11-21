using Avalonia.Controls;
using CraftPanel.App.ViewModels;

namespace CraftPanel.App.Views;

public partial class HelpWindow : Window
{
    public HelpWindow() => InitializeComponent();

    public HelpWindow(HelpViewModel vm) : this()
    {
        DataContext = vm;
        vm.RequestClose += () => Avalonia.Threading.Dispatcher.UIThread.Post(Close);
    }
}
