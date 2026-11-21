namespace CraftPanel.Core.Help;

/// <summary>Finds help: for a page, by search, or by id. Pure, so it's easy to test.</summary>
public static class HelpLibrary
{
    public static IReadOnlyList<HelpTopic> All => HelpContent.Topics;

    public static HelpTopic? Find(string id) => All.FirstOrDefault(t => t.Id == id);

    /// <summary>Topics for a page, in the order they're written (the most useful first).</summary>
    public static IReadOnlyList<HelpTopic> ForPage(string pageId) => All.Where(t => t.Pages.Contains(pageId)).ToList();

    /// <summary>
    /// Every word typed has to appear somewhere in a topic; title and keyword hits rank above hits in the steps.
    /// An empty query returns everything alphabetically.
    /// </summary>
    static readonly HashSet<string> Filler = ["a", "an", "the", "to", "how", "do", "does", "i", "me", "my", "myself", "yourself", "can", "is", "it", "on", "in", "of", "for", "and", "or", "with", "get", "make", "use", "want", "need", "please", "what", "where"];

    static HashSet<string> Words(string text) => System.Text.RegularExpressions.Regex.Matches(text, "[a-z0-9.']+").Select(m => m.Value.Trim('.', '\'')).Where(w => w.Length > 0).ToHashSet();

    public static IReadOnlyList<HelpTopic> Search(string? query)
    {
        var typed = (query ?? "").Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).Select(w => w.Trim('?', '!', '.', ',').ToLowerInvariant()).Where(w => w.Length > 0).ToArray();
        // "how do I make myself op?" → "op": filler words don't count (unless that's all there is)
        var words = typed.Where(w => !Filler.Contains(w)).ToArray();
        if (words.Length == 0) words = typed;
        if (words.Length == 0) return All.OrderBy(t => t.Title, StringComparer.OrdinalIgnoreCase).ToList();
        var scored = new List<(HelpTopic T, int Score)>();
        foreach (var t in All)
        {
            var title = t.Title.ToLowerInvariant();
            var keys = string.Join(' ', t.Keywords).ToLowerInvariant();
            var body = (t.Summary + " " + string.Join(' ', t.Steps.Select(s => s.Text)) + " " + string.Join(' ', t.Notes ?? [])).ToLowerInvariant();
            var titleWords = Words(title); var keyWords = Words(keys); var bodyWords = Words(body);
            var score = 0; var all = true;
            foreach (var w in words)
            {
                // a whole word beats a word that merely contains it ("op" is "operator", not "stop")
                var s = (titleWords.Contains(w) ? 20 : title.Contains(w) ? 5 : 0)
                      + (keyWords.Contains(w) ? 15 : keys.Contains(w) ? 3 : 0)
                      + (bodyWords.Contains(w) ? 2 : body.Contains(w) ? 1 : 0);
                if (s == 0) { all = false; break; }
                score += s;
            }
            if (all) scored.Add((t, score));
        }
        return scored.OrderByDescending(x => x.Score).ThenBy(x => x.T.Title, StringComparer.OrdinalIgnoreCase).Select(x => x.T).ToList();
    }
}
