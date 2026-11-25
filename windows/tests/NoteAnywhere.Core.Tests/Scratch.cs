using System.Runtime.CompilerServices;

namespace NoteAnywhere.Core.Tests;

/// This run's own store, in the temp folder: never %LOCALAPPDATA%, never anyone's notes.
static class Scratch
{
    public static readonly string Dir = Path.Combine(Path.GetTempPath(), "noteanywhere-tests-" + Guid.NewGuid().ToString("N"));

#pragma warning disable CA2255  // it must run before anything reads AppPaths.Data, which is fixed on first use
    [ModuleInitializer]
    internal static void Use() => Environment.SetEnvironmentVariable("NOTEANYWHERE_DIR", Dir);
#pragma warning restore CA2255
}
