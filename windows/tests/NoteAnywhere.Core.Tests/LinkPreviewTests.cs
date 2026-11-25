using NoteAnywhere.Core;

namespace NoteAnywhere.Core.Tests;

/// The Mac's LinkPreviewTests.swift (the parsing part): what a page's HTML yields. No network.
public class LinkPreviewTests
{
    [Fact]
    public void OpenGraphWins()
    {
        // Attributes in any order and either quote, entities, relative and protocol-relative addresses.
        var html = """
            <!doctype html><html><head>
            <meta charset="utf-8"><title>Ignored &ndash; title</title>
            <meta content='Quick Start &#x2013; React' property='og:title'>
            <meta name="twitter:title" content="Not this">
            <meta name="description" content="Plain description">
            <meta property="og:description" content="Welcome to the &quot;React&quot; docs!
                This page &amp; the next&#39;s &lt;b&gt;&nbsp;intro." />
            <meta property="og:image" content="/images/og-learn.png?a=1&amp;b=2">
            <link rel="icon" href="/favicon-32x32.png" sizes="32x32" type="image/png">
            <link href="//cdn.react.dev/apple-touch-icon.png" rel="apple-touch-icon" sizes="180x180">
            <link rel="icon" href="/favicon.svg" type="image/svg+xml">
            </head><body><title>An SVG's title</title></body></html>
            """;
        Assert.Equal(new LinkPreview.Page(
            "Quick Start – React",
            "Welcome to the \"React\" docs! This page & the next's <b> intro.",
            "https://cdn.react.dev/apple-touch-icon.png",
            "https://react.dev/images/og-learn.png?a=1&b=2"), LinkPreview.Parse(html, new Uri("https://react.dev/learn")));
    }

    [Fact]
    public void PlainHtml()
    {
        // No Open Graph: <title>, the description meta, the largest icon, resolved against <base href>.
        var html = """
            <HTML><HEAD><BASE HREF="https://static.example.com/site/">
            <TITLE>
              Bengaluru  &mdash;
              Wikipedia
            </TITLE>
            <META NAME="Description" CONTENT="Capital of Karnataka">
            <LINK REL="shortcut icon" HREF="small.ico" SIZES="16x16">
            <LINK REL="icon" HREF="big.png" SIZES="64x64">
            <LINK REL="mask-icon" HREF="mask.png">
            </HEAD><BODY>…</BODY></HTML>
            """;
        Assert.Equal(new LinkPreview.Page("Bengaluru — Wikipedia", "Capital of Karnataka", "https://static.example.com/site/big.png", ""),
            LinkPreview.Parse(html, new Uri("https://en.example.org/wiki/Bengaluru")));
    }

    [Fact]
    public void NothingButTheHost()
    {
        // Only an SVG icon (not kept), so the site's /favicon.ico stands in; the title is the host.
        var page = LinkPreview.Parse("""<html><head><link rel="icon" href="/icon.svg?v=2"></head><body><p>Hi</p></body></html>""",
            new Uri("https://react.dev/learn/thinking?x=1"));
        Assert.Equal(new LinkPreview.Page("react.dev", "", "https://react.dev/favicon.ico", ""), page);
        Assert.Equal("localhost", LinkPreview.Parse("<title> </title>", new Uri("http://localhost:3000/")).Title);
    }

    [Fact]
    public void LongDescriptionIsTrimmed()
    {
        var description = LinkPreview.Parse($"<meta name=description content=\"{string.Concat(Enumerable.Repeat("word ", 100))}\">",
            new Uri("https://a.com")).Description;
        Assert.True(description.Length <= 300 && description.EndsWith('…') && description.StartsWith("word word"));
    }
}
