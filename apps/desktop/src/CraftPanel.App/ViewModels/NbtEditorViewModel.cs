using System.Collections.ObjectModel;
using System.Globalization;
using CraftPanel.Core.Nbt;

namespace CraftPanel.App.ViewModels;

/// <summary>One row of the NBT tree: a container (compound/list) with children, or a value you can edit in place.</summary>
public sealed class NbtNodeViewModel : ViewModelBase
{
    const int MaxChildren = 500;
    const int MaxArrayEdit = 256;
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    readonly Action? _edited;
    string _text = "";
    bool _invalid, _expanded;

    public NbtTag? Tag { get; }
    public string Key { get; }
    public string TypeName { get; }
    public string Detail { get; } = "";
    public ObservableCollection<NbtNodeViewModel> Children { get; } = [];
    public bool IsContainer { get; }
    /// <summary>A value with an edit box (numbers, strings and short arrays).</summary>
    public bool IsEditable { get; }
    public bool IsNote { get; }

    public NbtNodeViewModel(string key, NbtTag tag, Action edited, int depth = 0)
    {
        Key = key; Tag = tag; _edited = edited; TypeName = tag.TypeName;
        switch (tag)
        {
            case NbtCompound c:
                IsContainer = true; Detail = $"{c.Entries.Count} {(c.Entries.Count == 1 ? "entry" : "entries")}";
                foreach (var (k, v) in c.Entries.Take(MaxChildren)) Children.Add(new NbtNodeViewModel(k, v, edited, depth + 1));
                if (c.Entries.Count > MaxChildren) Children.Add(Note(c.Entries.Count - MaxChildren));
                break;
            case NbtList l:
                IsContainer = true; Detail = $"{l.Items.Count} {(l.Items.Count == 1 ? "item" : "items")}";
                for (var i = 0; i < Math.Min(l.Items.Count, MaxChildren); i++) Children.Add(new NbtNodeViewModel($"[{i}]", l.Items[i], edited, depth + 1));
                if (l.Items.Count > MaxChildren) Children.Add(Note(l.Items.Count - MaxChildren));
                break;
            case NbtByteArray { Value.Length: > MaxArrayEdit } a: Detail = $"{a.Value.Length} values (too long to edit here)"; break;
            case NbtIntArray { Value.Length: > MaxArrayEdit } a: Detail = $"{a.Value.Length} values (too long to edit here)"; break;
            case NbtLongArray { Value.Length: > MaxArrayEdit } a: Detail = $"{a.Value.Length} values (too long to edit here)"; break;
            default: IsEditable = true; _text = Format(tag); break;
        }
        _expanded = depth < 2;
    }

    NbtNodeViewModel(string note)
    {
        Key = note; TypeName = ""; IsNote = true;
    }

    static NbtNodeViewModel Note(int more) => new($"… {more} more not shown (they're kept unchanged when you save)");

    public bool IsExpanded { get => _expanded; set => Set(ref _expanded, value); }
    public bool HasDetail => Detail.Length > 0;
    public bool Invalid { get => _invalid; private set => Set(ref _invalid, value); }

    /// <summary>The value as text. Input that doesn't fit the tag's type is flagged and not applied, so the file can't be made unreadable.</summary>
    public string Text
    {
        get => _text;
        set
        {
            if (!Set(ref _text, value)) return;
            Invalid = !TryApply(value);
            if (!Invalid) _edited?.Invoke();
        }
    }

    bool TryApply(string raw)
    {
        var t = raw.Trim();
        static bool List<T>(string s, TryParse<T> p, out T[] result)
        {
            var parts = s.Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
            result = new T[parts.Length];
            for (var i = 0; i < parts.Length; i++) if (!p(parts[i], out result[i]!)) return false;
            return true;
        }
        switch (Tag)
        {
            case NbtByte x when sbyte.TryParse(t, NumberStyles.AllowLeadingSign, Inv, out var v): x.Value = v; return true;
            case NbtShort x when short.TryParse(t, NumberStyles.AllowLeadingSign, Inv, out var v): x.Value = v; return true;
            case NbtInt x when int.TryParse(t, NumberStyles.AllowLeadingSign, Inv, out var v): x.Value = v; return true;
            case NbtLong x when long.TryParse(t, NumberStyles.AllowLeadingSign, Inv, out var v): x.Value = v; return true;
            case NbtFloat x when float.TryParse(t, NumberStyles.Float, Inv, out var v) && float.IsFinite(v): x.Value = v; return true;
            case NbtDouble x when double.TryParse(t, NumberStyles.Float, Inv, out var v) && double.IsFinite(v): x.Value = v; return true;
            case NbtString x: x.Value = raw; return true;
            case NbtByteArray x when List<sbyte>(t, (string s, out sbyte r) => sbyte.TryParse(s, Inv, out r), out var arr): x.Value = arr; return true;
            case NbtIntArray x when List<int>(t, (string s, out int r) => int.TryParse(s, Inv, out r), out var arr): x.Value = arr; return true;
            case NbtLongArray x when List<long>(t, (string s, out long r) => long.TryParse(s, Inv, out r), out var arr): x.Value = arr; return true;
            default: return false;
        }
    }

    delegate bool TryParse<T>(string s, out T value);

    public static string Format(NbtTag t) => t switch
    {
        NbtByte v => v.Value.ToString(Inv),
        NbtShort v => v.Value.ToString(Inv),
        NbtInt v => v.Value.ToString(Inv),
        NbtLong v => v.Value.ToString(Inv),       // edited as text so 64-bit seeds are never rounded
        NbtFloat v => v.Value.ToString("R", Inv),
        NbtDouble v => v.Value.ToString("R", Inv),
        NbtString v => v.Value,
        NbtByteArray v => string.Join(", ", v.Value),
        NbtIntArray v => string.Join(", ", v.Value),
        NbtLongArray v => string.Join(", ", v.Value),
        _ => "",
    };

    public void SetExpandedRecursive(bool on)
    {
        IsExpanded = on;
        foreach (var c in Children) c.SetExpandedRecursive(on);
    }
}

/// <summary>Edits <c>level.dat</c>, player data and other NBT files as a tree. Saving keeps the previous file as <c>.craftpanel-bak</c> and the gzip/plain form it had.</summary>
public sealed class NbtEditorViewModel : ViewModelBase
{
    readonly string _path;
    readonly bool _running;
    NbtFile? _file;
    byte[] _original = [];
    string _error = "";
    bool _dirty, _saving;

    public string Title { get; }
    public string Heading => "NBT editor";
    public ObservableCollection<NbtNodeViewModel> Roots { get; } = [];
    public event Action? RequestClose;

    public NbtEditorViewModel(string path, string title, bool serverRunning)
    {
        _path = path; Title = title; _running = serverRunning;
        SaveCommand = new AsyncCommand(SaveAsync, () => CanSave);
        CloseCommand = new RelayCommand(() => RequestClose?.Invoke());
        ExpandAllCommand = new RelayCommand(() => { foreach (var r in Roots) r.SetExpandedRecursive(true); });
        CollapseAllCommand = new RelayCommand(() => { foreach (var r in Roots) { r.SetExpandedRecursive(false); r.IsExpanded = true; } });
        Load();
    }

    public bool ServerRunning => _running;
    public string Error { get => _error; private set { Set(ref _error, value); Raise(nameof(HasError)); } }
    public bool HasError => _error.Length > 0;
    public bool Loaded => _file is not null;
    public bool Dirty { get => _dirty; private set { if (Set(ref _dirty, value)) { Raise(nameof(CanSave)); SaveCommand.RaiseCanExecuteChanged(); } } }
    public bool CanSave => _file is not null && _dirty && !_running && !_saving;
    public string SaveLabel => _saving ? "Saving…" : "Save";
    public string FormatNote => _file is null ? "" : _file.Gzip ? "compressed (gzip)" : "uncompressed";

    public AsyncCommand SaveCommand { get; }
    public RelayCommand CloseCommand { get; }
    public RelayCommand ExpandAllCommand { get; }
    public RelayCommand CollapseAllCommand { get; }

    void Load()
    {
        try
        {
            _file = Nbt.Read(_path);
            _original = Nbt.Encode(_file.Name, _file.Root);
            Roots.Add(new NbtNodeViewModel(_file.Name.Length == 0 ? "(root)" : _file.Name, _file.Root, OnEdited));
        }
        catch (Exception e) { Error = e is NbtException ? e.Message : "Couldn't open this file: " + e.Message; }
        Raise(nameof(Loaded)); Raise(nameof(FormatNote)); Raise(nameof(CanSave));
    }

    void OnEdited()
    {
        if (_file is null) return;
        // Save is only on when something really differs, so changing a value and back again leaves it off.
        Dirty = !Nbt.Encode(_file.Name, _file.Root).AsSpan().SequenceEqual(_original);
    }

    async Task SaveAsync()
    {
        if (_file is null) return;
        _saving = true; Raise(nameof(SaveLabel)); Raise(nameof(CanSave)); SaveCommand.RaiseCanExecuteChanged();
        try
        {
            var f = _file;
            await Task.Run(() => Nbt.Write(_path, f));
            _original = Nbt.Encode(f.Name, f.Root);
            Error = "";
            Dirty = false;
            Services.ToastService.Shared.Show("Saved", Title, "check-circle", "ok", null, 2);
        }
        catch (Exception e) { Error = "Couldn't save: " + e.Message; }
        finally { _saving = false; Raise(nameof(SaveLabel)); Raise(nameof(CanSave)); SaveCommand.RaiseCanExecuteChanged(); }
    }
}
