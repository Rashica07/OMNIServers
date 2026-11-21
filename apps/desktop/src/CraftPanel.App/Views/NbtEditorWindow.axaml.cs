using Avalonia.Controls;
using CraftPanel.App.ViewModels;

namespace CraftPanel.App.Views;

public partial class NbtEditorWindow : Window
{
    public NbtEditorWindow() => InitializeComponent();

    public NbtEditorWindow(NbtEditorViewModel vm) : this()
    {
        DataContext = vm;
        vm.RequestClose += () => Avalonia.Threading.Dispatcher.UIThread.Post(Close);
    }
}
