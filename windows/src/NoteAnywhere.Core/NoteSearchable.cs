using NoteAnywhere.Core.Search;

namespace NoteAnywhere.Core;

/// The store's notes are what search ranks.
public sealed partial record Note : ISearchableNote
{
    IReadOnlyList<string> ISearchableNote.Tags => Tags;
}
