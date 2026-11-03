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
    // Link cards and mentions (Notion-style previews) read as their titles; the card's pictures as nothing.
    ("> [!bookmark] [Quick Start – React](https://react.dev/learn)", "Quick Start – React"),
    ("> Welcome to the React docs!", "Welcome to the React docs!"),
    ("> ![](noteimage:abc \"icon\") ![](noteimage:def)", ""),
    ("See [Quick Start – React](https://react.dev/learn \"mention noteimage:abc\") first", "See Quick Start – React first"),
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

@Test func datedRanges() {
    let note = Note(id: "n", kind: .url, target: "", label: "", text: """
        Rohin Wedding @2026-12-03 - @2026-12-06
        Trip @2026-12-31 to @2027-01-01, call @2026-12-20
        Backwards @2026-12-10 – @2026-12-09
        Same day @2026-12-15 - @2026-12-15
        """)
    let wedding = note.dates.filter { $0.line == 0 }
    #expect(wedding.map(\.day) == ["2026-12-03", "2026-12-04", "2026-12-05", "2026-12-06"])
    #expect(wedding.allSatisfy { $0.isRange && $0.first == "2026-12-03" && $0.last == "2026-12-06" && $0.text == "Rohin Wedding" })
    let trip = note.dates.filter { $0.line == 1 }
    #expect(trip.map(\.day) == ["2026-12-20", "2026-12-31", "2027-01-01"])  // across a year, and the single date too
    #expect(trip.map(\.isRange) == [false, true, true])
    #expect(trip[0].text == "Trip , call")
    #expect(note.dates.filter { $0.line == 2 }.map(\.day) == ["2026-12-09", "2026-12-10"])
    #expect(note.dates.filter { $0.line == 3 }.map(\.isRange) == [false])  // a one-day "range" is just a date
    #expect(DatedLine.days(from: "2026-01-01", to: "2099-01-01").count == 366)
}

@Test func rangesKeepTheirRowAndColour() {
    let note = Note(id: "n", kind: .url, target: "", label: "", text: """
        Dentist @2026-12-04
        Short @2026-12-04 - @2026-12-05
        Long @2026-12-03 - @2026-12-06
        """)
    let dec4 = DatedLine.byDay(note.dates)["2026-12-04"]!
    #expect(dec4.map(\.text) == ["Long", "Short", "Dentist"])  // earliest start first, then single days
    #expect(dec4[0].barColor(label: .purple) == .purple)  // the note's colour label wins
    #expect(dec4[0].barColor(label: nil) == dec4[0].barColor(label: nil))
    #expect(dec4[0].barColor(label: nil) != .grey && dec4[0].barColor(label: nil) != .yellow)
}

@Test func eventsKeepTheirOwnColour() {
    let note = Note(id: "n", kind: .url, target: "", label: "", text: """
        Dentist @2026-11-05{red} and gym @2026-11-06
        Goa @2026-11-15{green} – @2026-11-12, odd @2026-11-20{bogus}
        """)
    let byDay = Dictionary(grouping: note.dates, by: \.day)
    #expect(byDay["2026-11-05"]?.first?.color == .red)
    #expect(byDay["2026-11-06"]?.first?.color == nil)
    #expect(note.dates.filter(\.isRange).allSatisfy { $0.color == .green && $0.first == "2026-11-12" })
    #expect(byDay["2026-11-20"]?.first?.color == nil)
    #expect(note.dates.first?.text == "Dentist and gym")  // the colour isn't part of the event's words
    #expect(byDay["2026-11-05"]![0].barColor(label: .blue) == .red)  // its own colour beats the note's label
    #expect(byDay["2026-11-06"]![0].barColor(label: .blue) == .blue)
    #expect(Note.plain("Dentist @2026-11-05{red}") == "Dentist \(DateStyle.format("2026-11-05"))")

    let lines = note.text.split(separator: "\n").map(String.init)
    let gym = byDay["2026-11-06"]![0], dentist = byDay["2026-11-05"]![0], goa = byDay["2026-11-13"]![0]
    #expect(gym.recolor(lines[0], .purple) == "Dentist @2026-11-05{red} and gym @2026-11-06{purple}")
    #expect(dentist.recolor(lines[0], nil) == "Dentist @2026-11-05 and gym @2026-11-06")
    #expect(dentist.recolor(lines[0], .cyan) == "Dentist @2026-11-05{cyan} and gym @2026-11-06")
    // A range takes one colour, on the date written first, whichever end that is.
    let orange = goa.recolor(lines[1], .orange)
    #expect(orange == "Goa @2026-11-15{orange} – @2026-11-12, odd @2026-11-20{bogus}")
    #expect(Note(id: "n", kind: .url, target: "", label: "", text: orange).dates.filter(\.isRange).allSatisfy { $0.color == .orange })
    #expect(goa.recolor("Goa @2026-11-15{green} – @2026-11-12{red}", nil) == "Goa @2026-11-15 – @2026-11-12")
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
