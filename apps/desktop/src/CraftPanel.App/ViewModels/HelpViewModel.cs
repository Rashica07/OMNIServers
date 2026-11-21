using System.Collections.ObjectModel;
using CraftPanel.Core.Help;

namespace CraftPanel.App.ViewModels;

public enum HelpMode { ThisPage, Tour, Library }

public sealed record StepRow(int Number, string Text, HelpAction? Action)
{
    public bool HasAction => Action is not null;
    public string ActionLabel => Action?.Label ?? "";
}

/// <summary>The Help window: tips for the page you're on, the full tour, and a searchable "How do I…?" library.</summary>
public sealed class HelpViewModel : ViewModelBase
{
    readonly Action<HelpAction> _act;
    readonly string _page;
    HelpMode _mode;
    HelpTopic? _selected;
    string _query = "";
    int _tour;

    public ObservableCollection<HelpTopic> Topics { get; } = [];
    public ObservableCollection<StepRow> Steps { get; } = [];

    public HelpViewModel(string pageId, bool startTour, Action<HelpAction> act)
    {
        _page = pageId; _act = act;
        ShowPageCommand = new RelayCommand(() => SetMode(HelpMode.ThisPage));
        ShowTourCommand = new RelayCommand(() => { _tour = 0; SetMode(HelpMode.Tour); });
        ShowLibraryCommand = new RelayCommand(() => SetMode(HelpMode.Library));
        NextCommand = new RelayCommand(() => { if (_tour < HelpContent.Tour.Count - 1) { _tour++; RaiseTour(); } else CloseCommand.Execute(null); });
        BackCommand = new RelayCommand(() => { if (_tour > 0) { _tour--; RaiseTour(); } }, () => _tour > 0);
        RunActionCommand = new RelayCommand(p => { if (p is HelpAction a) _act(a); });
        CloseCommand = new RelayCommand(() => RequestClose?.Invoke());
        // With no tips for this page, start in the library instead of an empty list.
        SetMode(startTour ? HelpMode.Tour : HelpLibrary.ForPage(pageId).Count > 0 ? HelpMode.ThisPage : HelpMode.Library);
    }

    public event Action? RequestClose;

    public HelpMode Mode => _mode;
    public bool IsPage => _mode == HelpMode.ThisPage;
    public bool IsTour => _mode == HelpMode.Tour;
    public bool IsLibrary => _mode == HelpMode.Library;
    public bool ShowsTopics => _mode != HelpMode.Tour;
    public string PageName => HelpPages.All.GetValueOrDefault(_page, "this page");
    public string PageHeading => $"Help for {PageName}";

    public string Query { get => _query; set { if (Set(ref _query, value) && _mode == HelpMode.Library) Reload(); } }

    public HelpTopic? Selected
    {
        get => _selected;
        set { if (Set(ref _selected, value)) RaiseTopic(); }
    }

    public bool HasSelected => _selected is not null;
    public bool NoTopics => Topics.Count == 0;
    public string TopicTitle => _selected?.Title ?? "";
    public string TopicSummary => _selected?.Summary ?? "";
    public bool HasNotes => _selected?.Notes is { Length: > 0 };
    public IReadOnlyList<string> Notes => _selected?.Notes ?? [];

    // ---- tour -----------------------------------------------------------------------------------------

    public TourStep CurrentTour => HelpContent.Tour[_tour];
    public string TourTitle => CurrentTour.Title;
    public string TourText => CurrentTour.Text;
    public bool TourHasAction => CurrentTour.Action is not null;
    public string TourActionLabel => CurrentTour.Action?.Label ?? "";
    public HelpAction? TourAction => CurrentTour.Action;
    public string TourProgress => $"Step {_tour + 1} of {HelpContent.Tour.Count}";
    public double TourFraction => (double)(_tour + 1) / HelpContent.Tour.Count;
    public string NextLabel => _tour == HelpContent.Tour.Count - 1 ? "Finish" : "Next";

    public RelayCommand ShowPageCommand { get; }
    public RelayCommand ShowTourCommand { get; }
    public RelayCommand ShowLibraryCommand { get; }
    public RelayCommand NextCommand { get; }
    public RelayCommand BackCommand { get; }
    public RelayCommand RunActionCommand { get; }
    public RelayCommand CloseCommand { get; }

    void SetMode(HelpMode m)
    {
        _mode = m;
        foreach (var n in new[] { nameof(Mode), nameof(IsPage), nameof(IsTour), nameof(IsLibrary), nameof(ShowsTopics) }) Raise(n);
        if (m == HelpMode.Tour) RaiseTour(); else Reload();
    }

    void Reload()
    {
        Topics.Clear();
        foreach (var t in _mode == HelpMode.ThisPage ? HelpLibrary.ForPage(_page) : HelpLibrary.Search(_query)) Topics.Add(t);
        Raise(nameof(NoTopics));
        Selected = Topics.FirstOrDefault();
    }

    void RaiseTopic()
    {
        Steps.Clear();
        if (_selected is { } t) for (var i = 0; i < t.Steps.Length; i++) Steps.Add(new StepRow(i + 1, t.Steps[i].Text, t.Steps[i].Action));
        foreach (var n in new[] { nameof(HasSelected), nameof(TopicTitle), nameof(TopicSummary), nameof(HasNotes), nameof(Notes) }) Raise(n);
    }

    void RaiseTour()
    {
        foreach (var n in new[] { nameof(CurrentTour), nameof(TourTitle), nameof(TourText), nameof(TourHasAction), nameof(TourActionLabel), nameof(TourAction), nameof(TourProgress), nameof(TourFraction), nameof(NextLabel) }) Raise(n);
        BackCommand.RaiseCanExecuteChanged();
    }
}
