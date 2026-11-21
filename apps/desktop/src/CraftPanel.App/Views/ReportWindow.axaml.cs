using Avalonia.Controls;
using CraftPanel.App.ViewModels;

namespace CraftPanel.App.Views;

public partial class ReportWindow : Window
{
    public ReportWindow() => InitializeComponent();

    public ReportWindow(ReportViewModel vm) : this()
    {
        DataContext = vm;
        vm.RequestClose += () => Avalonia.Threading.Dispatcher.UIThread.Post(Close);
    }
}
