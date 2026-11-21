using System.Collections.Specialized;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Threading;
using CraftPanel.App.ViewModels;

namespace CraftPanel.App.Views;

public partial class ChatView : UserControl
{
    bool _follow = true;

    public ChatView()
    {
        InitializeComponent();
        Scroller.ScrollChanged += (_, e) =>
        {
            var nearBottom = Scroller.Offset.Y + Scroller.Viewport.Height >= Scroller.Extent.Height - 40;
            if (nearBottom) _follow = true; else if (e.OffsetDelta.Y < -1) _follow = false;
            JumpButton.IsVisible = !_follow;
        };
        DraftBox.KeyDown += (_, e) => { if (e.Key == Key.Enter && DataContext is ChatViewModel vm) { vm.SendCommand.Execute(null); e.Handled = true; } };
        DataContextChanged += (_, _) =>
        {
            if (DataContext is ChatViewModel vm)
                vm.Messages.CollectionChanged += (_, _) => { if (_follow) Dispatcher.UIThread.Post(() => Scroller.ScrollToEnd(), DispatcherPriority.Background); };
            Dispatcher.UIThread.Post(() => Scroller.ScrollToEnd(), DispatcherPriority.Background);
        };
    }

    void OnJumpClick(object? s, RoutedEventArgs e) { _follow = true; JumpButton.IsVisible = false; Scroller.ScrollToEnd(); }
}
