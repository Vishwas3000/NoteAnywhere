using NoteAnywhere.Core;

namespace NoteAnywhere.Core.Tests;

public class SettingsTests
{
    [Fact]
    public void DefaultsThenWhatWasSaved()
    {
        var file = Path.Combine(AppPaths.Data, "settings.json");
        if (File.Exists(file)) File.Delete(file);
        Assert.Equal(new Settings(), Settings.Load());
        new Settings { Appearance = "dark", OpenNotesByThemselves = false }.Save();
        Assert.Equal(new Settings { Appearance = "dark", OpenNotesByThemselves = false }, Settings.Load());
        File.WriteAllText(file, "{ not json");
        Assert.Equal(new Settings(), Settings.Load());
    }
}
