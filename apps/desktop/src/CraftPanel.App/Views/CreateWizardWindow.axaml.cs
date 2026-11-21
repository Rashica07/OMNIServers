using Avalonia.Controls;
using Avalonia.Input;
using CraftPanel.App.ViewModels;

namespace CraftPanel.App.Views;

public partial class CreateWizardWindow : Window
{
    public CreateWizardWindow() : this(new CreateWizardViewModel(Services.WizardMode.Custom)) { }

    public CreateWizardWindow(CreateWizardViewModel vm)
    {
        InitializeComponent();
        DataContext = vm;
        vm.RequestClose += () => Avalonia.Threading.Dispatcher.UIThread.Post(Close);
        PackSearch.KeyDown += (_, e) => { if (e.Key == Key.Enter) { vm.SearchPacksCommand.Execute(null); e.Handled = true; } };
        Closing += (_, _) => vm.Cancel();
    }
}
