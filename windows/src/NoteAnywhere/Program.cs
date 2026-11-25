namespace NoteAnywhere;

/// One program in three roles, as on the Mac (docs/ARCHITECTURE.md): browsers start it as their native messaging host,
/// AI apps as an MCP server (--mcp), and otherwise it's the app. The role is picked here, before WPF starts.
static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        var app = new App();
        app.InitializeComponent();
        return app.Run();
    }
}
