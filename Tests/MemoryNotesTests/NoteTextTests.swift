import Foundation
import Testing
@testable import MemoryNotes

@Test(arguments: [
    ("# Title", "Title"),
    ("- [ ] Implement the key rotation", "Implement the key rotation"),
    ("- [x] done", "done"),
    ("1. Cross entropy and **how** it works", "Cross entropy and how it works"),
    ("> quoted *it* ~~gone~~ `code`", "quoted it gone code"),
    ("See [the docs](https://example.com) and ![pic](a.png)", "See the docs and pic"),
    ("snake_case_name stays", "snake_case_name stays"),
    ("2 * 3 = 6", "2 * 3 = 6"),
    ("| A | B |", "A  B"),
    ("| --- | --- |", ""),
    ("---", ""),
])
func plainLine(markdown: String, expected: String) {
    #expect(Note.plain(Substring(markdown)) == expected)
}

@Test func titleAndPreview() {
    let note = Note(kind: .app, target: "x", label: "X", text: "\n# Plan\n\n- [ ] one\n```\ncode\n```\n- two")
    #expect(note.title == "Plan")
    #expect(note.preview == "one code two")
    #expect(Note(kind: .app, target: "x", label: "X").title == "New Note")
}

@Test(arguments: [
    ("https://www.github.com/vercel/next.js/", "github.com/vercel/next.js"),
    ("https://GitHub.com/?tab=1#top", "github.com"),
    ("http://localhost:3000/a%20b", "localhost:3000/a%20b"),
    ("mailto:someone@example.com", ""),
])
func pageTargets(url: String, expected: String) {
    #expect(Note.pageTarget(URL(string: url)!) == expected)
}

@Test func obsidianTags() {
    let note = Note(kind: .url, target: "x", label: "", text: """
        # Heading is not a tag
        Plan for #ML and #ml again, #project/notes, (#paren) and #2024.
        `#code` and [link](https://x.com/#anchor) and a#mid
        ```
        #fenced
        ```
        - [ ] ship #release-1
        """)
    #expect(note.tags == ["ml", "project/notes", "paren", "release-1"])
    #expect(note.hasTag("project") && note.hasTag("project/notes") && !note.hasTag("proj"))
}

@Test func datedLines() {
    let note = Note(id: "n", kind: .url, target: "", label: "", text: """
        # Launch plan
        - [ ] send build to QA @2026-10-30
        - [x] book room 📅 2026-10-29
        Party on @2026-11-01 and @2026-11-01, not `@2026-11-02`, not me@2026-11-03 or @2026-02-30
        ```
        @2026-11-04
        ```
        """)
    #expect(note.dates.map(\.day) == ["2026-10-30", "2026-10-29", "2026-11-01"])
    #expect(note.dates.map(\.text) == ["send build to QA", "book room", "Party on and , not , not me or"])
    #expect(note.dates.map(\.isTask) == [true, true, false])
    #expect(note.dates.map(\.done) == [false, true, false])
    #expect(note.dates.map(\.line) == [1, 2, 3])
}

@Test func pageFromHighlightLinksBack() {
    var parent = Note(kind: .url, target: "", label: "", updatedAt: 0)
    parent.text = "Sync [notes]\nWhy does sync lag?"
    let text = NotesModel.pageText("Why does\nsync lag?", backTo: parent)
    #expect(text == "Why does sync lag?\n\n↖ [Sync [notes\\]](note://\(parent.id))\n\n")
    var page = Note(kind: .url, target: "", label: "", updatedAt: 0)
    page.text = text
    #expect(page.title == "Why does sync lag?")
    #expect(page.preview == "", "the ↖ link back isn't shown as the page's text")
    page.text += "Supabase closes idle sockets."
    #expect(page.preview == "Supabase closes idle sockets.")
    #expect(NotesModel.pageText("Alone", backTo: nil) == "Alone\n\n")
}
