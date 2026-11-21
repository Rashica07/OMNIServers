using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Windows.Input;
using Avalonia.Threading;

namespace CraftPanel.App.ViewModels;

public abstract class ViewModelBase : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }

    protected void Raise([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public sealed class RelayCommand(Action<object?> execute, Func<object?, bool>? canExecute = null) : ICommand
{
    public RelayCommand(Action execute, Func<bool>? canExecute = null) : this(_ => execute(), canExecute is null ? null : _ => canExecute()) { }
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? p) => canExecute?.Invoke(p) ?? true;
    public void Execute(object? p) => execute(p);
    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

/// <summary>Async command: ignores re-entry while running and reports failures through <see cref="Ui.Error"/>.</summary>
public sealed class AsyncCommand(Func<object?, Task> run, Func<object?, bool>? canExecute = null) : ICommand
{
    public AsyncCommand(Func<Task> run, Func<bool>? canExecute = null) : this(_ => run(), canExecute is null ? null : _ => canExecute()) { }
    bool _busy;
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? p) => !_busy && (canExecute?.Invoke(p) ?? true);
    public async void Execute(object? p)
    {
        if (_busy) return;
        _busy = true; CanExecuteChanged?.Invoke(this, EventArgs.Empty);
        try { await run(p); }
        catch (Exception e) when (e is not OperationCanceledException) { Ui.Error?.Invoke(e); }
        finally { _busy = false; CanExecuteChanged?.Invoke(this, EventArgs.Empty); }
    }
    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

public static class Ui
{
    public static void Post(Action a) { if (Dispatcher.UIThread.CheckAccess()) a(); else Dispatcher.UIThread.Post(a); }
    /// <summary>Global sink for unexpected command failures (shown as a toast).</summary>
    public static Action<Exception>? Error { get; set; }
}
