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
