using NoteAnywhere.Core;

namespace NoteAnywhere.Core.Tests;

public class AssistantTests
{
    sealed class Model(string reply, string? unavailable = null) : IWritingModel
    {
        public string? UnavailableReason => unavailable;
        public string? Asked;
        public Task<string> Respond(string instructions, string text, CancellationToken cancel) { Asked = instructions; return Task.FromResult(reply); }
    }

    [Theory]
    [InlineData("```markdown\n- [ ] a\n```", "- [ ] a")]
    [InlineData("```\nplain\n```", "plain")]
    [InlineData("“Weekly plan”", "Weekly plan")]
    [InlineData("\"Quoted\"", "Quoted")]
    [InlineData("  as is  ", "as is")]
    [InlineData("\"", "\"")]
    public void CleansFencesAndQuotes(string reply, string expected) => Assert.Equal(expected, Assistant.Clean(reply));

    [Fact]
    public async Task RunsWithTheMacsInstructions()
    {
        var model = new Model("```md\n- [ ] Call Sam\n```");
        Assert.Equal("- [ ] Call Sam", await Assistant.Run(model, Assistant.Action.Checklist, "call sam"));
        Assert.StartsWith("You edit personal notes written in Markdown. Turn it into a Markdown checklist", model.Asked);
        Assert.Equal(Assistant.Action.Title, Assistant.Parse("title"));
        Assert.Null(Assistant.Parse("translate"));
    }

    /// What EditorView's "ai" message does with the page's { action, text }.
    [Fact]
    public async Task RunsTheEditorsRequest()
    {
        Assert.Equal("Call Sam", await Assistant.Run(new Model("“Call Sam”"), "title", "call sam"));
        Assert.Equal("Unknown action.", (await Assert.ThrowsAsync<InvalidOperationException>(() => Assistant.Run(new Model("x"), "translate", "text"))).Message);
        Assert.Equal("Unknown action.", (await Assert.ThrowsAsync<InvalidOperationException>(() => Assistant.Run(new Model("x"), null, "text"))).Message);
        Assert.Equal("Write something first.", (await Assert.ThrowsAsync<InvalidOperationException>(() => Assistant.Run(new Model("x"), "title", null))).Message);
    }

    [Fact]
    public async Task SaysWhyItCantRun()
    {
        var missing = await Assert.ThrowsAsync<InvalidOperationException>(() => Assistant.Run(new Model("x", "Download the writing model first."), Assistant.Action.Improve, "text"));
        Assert.Equal("Download the writing model first.", missing.Message);
        var empty = await Assert.ThrowsAsync<InvalidOperationException>(() => Assistant.Run(new Model("x"), Assistant.Action.Improve, "  \n"));
        Assert.Equal("Write something first.", empty.Message);
    }
}
