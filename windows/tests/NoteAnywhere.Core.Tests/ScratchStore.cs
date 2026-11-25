using System.Runtime.CompilerServices;

namespace NoteAnywhere.Core.Tests;

/// Every test in this project uses a scratch folder: set before any test runs, since AppPaths reads it once.
static class ScratchStore
{
    [ModuleInitializer]
    internal static void Use() =>
        Environment.SetEnvironmentVariable("NOTEANYWHERE_DIR", Path.Combine(Path.GetTempPath(), "na-tests-" + Environment.ProcessId));
}
