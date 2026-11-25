using System.Text.RegularExpressions;

namespace NoteAnywhere.Core;

/// One-click edits (✨) with an on-device model, as the Mac's Assistant.swift: the same five actions and the same
/// instructions, so both apps give the same kind of result. On Windows the model is downloaded once the person agrees
/// (D86); the app supplies it through IWritingModel.
public static partial class Assistant
{
    public enum Action { Proofread, Improve, Shorten, Checklist, Title }

    public static Action? Parse(string? name) => name switch
    {
        "proofread" => Action.Proofread, "improve" => Action.Improve, "shorten" => Action.Shorten,
        "checklist" => Action.Checklist, "title" => Action.Title, _ => null,
    };

    public static string Instruction(Action action) => action switch
    {
        Action.Proofread => "Fix spelling, grammar and punctuation. Change nothing else: keep the wording, tone and meaning.",
        Action.Improve => "Rewrite it to be clearer and better organized. Keep the meaning, the facts and the author's voice.",
        Action.Shorten => "Make it shorter and more concise. Keep every important fact, name, number and link.",
        Action.Checklist => "Turn it into a Markdown checklist of concrete action items, one per line, each starting with \"- [ ] \".",
        _ => "Write a short title (at most 7 words) for this note. Reply with the title only, no quotes or punctuation at the end.",
    };

    /// The system prompt, word for word the Mac's.
    public static string Instructions(Action action) =>
        $"You edit personal notes written in Markdown. {Instruction(action)}\n"
        + "Keep Markdown formatting (headings, lists, checkboxes, links, code) unless asked to change it.\n"
        + "Reply with the result only: no preamble, no explanation, no surrounding code fence.";

    /// A ✨ request as the editor sends it (and the browser's, through the host): the action's name and the text.
    public static async Task<string> Run(IWritingModel model, string? action, string? markdown, CancellationToken cancel = default) =>
        await Run(model, Parse(action) ?? throw new InvalidOperationException("Unknown action."), markdown ?? "", cancel);

    /// Returns the rewritten Markdown; for Title, just the title. Throws with a message to show.
    public static async Task<string> Run(IWritingModel model, Action action, string markdown, CancellationToken cancel = default)
    {
        if (model.UnavailableReason is { } reason) throw new InvalidOperationException(reason);
        if (string.IsNullOrWhiteSpace(markdown)) throw new InvalidOperationException("Write something first.");
        return Clean(await model.Respond(Instructions(action), markdown, cancel));
    }

    /// Models sometimes wrap the answer in a fence or quotes anyway.
    public static string Clean(string reply)
    {
        var text = reply.Trim();
        if (text.StartsWith("```") && text.EndsWith("```") && text.Length > 6) text = FenceLanguage().Replace(text[3..^3], "");
        if (text.Length > 1 && "\"“".Contains(text[0]) && "\"”".Contains(text[^1])) text = text[1..^1];
        return text.Trim();
    }

    [GeneratedRegex(@"^(markdown|md)?\n")] private static partial Regex FenceLanguage();
}

/// The writing model the ✨ actions run on: on Windows, one downloaded after asking (phase 3 of D86).
public interface IWritingModel
{
    /// Why it can't run now (not downloaded yet, too little memory…), or null when it can.
    string? UnavailableReason { get; }
    Task<string> Respond(string instructions, string text, CancellationToken cancel);
}
