using Avalonia.Controls;
using Avalonia.Input;
using CraftPanel.App.Services;

namespace CraftPanel.App.Views;

public partial class LockWindow : Window
{
    int _fails;

    public bool Unlocked { get; private set; }

    public LockWindow()
    {
        InitializeComponent();
        UnlockButton.Click += async (_, _) => await TryUnlock();
        PinBox.KeyDown += async (_, e) => { if (e.Key == Key.Enter) await TryUnlock(); };
        Opened += (_, _) => PinBox.Focus();
    }

    async Task TryUnlock()
    {
        var pin = PinBox.Text ?? "";
        UnlockButton.IsEnabled = false;
        var ok = await Task.Run(() => AppServices.Lock.Verify(pin));
        if (ok) { Unlocked = true; Close(); return; }
        _fails++;
        ErrorText.Text = "That's not right.";
        ErrorText.IsVisible = true;
        PinBox.Text = "";
        if (_fails >= 3) await Task.Delay(Math.Min(30, _fails * 2) * 1000);   // slow down guessing
        UnlockButton.IsEnabled = true;
        PinBox.Focus();
    }
}
