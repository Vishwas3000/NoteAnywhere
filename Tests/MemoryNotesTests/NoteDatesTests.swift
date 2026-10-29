import Foundation
import Testing
@testable import MemoryNotes

private let calendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.locale = Locale(identifier: "en_US")
    return c
}()

private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: h == 14 ? 14 : 5))!
}

private func edited(_ date: Date) -> Note {
    Note(kind: .app, target: "x", label: "X", updatedAt: date.timeIntervalSince1970 * 1000)
}

private let now = day(2026, 10, 28, 14)  // a Wednesday

@Test func sectionsLikeAppleNotes() {
    let dates = [
        day(2025, 12, 1), day(2026, 9, 27), day(2026, 9, 28), day(2026, 10, 20), day(2026, 10, 21),
        day(2026, 10, 22), day(2026, 10, 27, 0), day(2026, 10, 28, 0), day(2026, 10, 29),  // the last one: a clock change
    ]
    let sections = NoteDates.sections(dates.map(edited), now: now, calendar: calendar)
    #expect(sections.map(\.title) == ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "September 2026", "December 2025"])
    #expect(sections.map(\.notes.count) == [2, 1, 2, 2, 1, 1])
    #expect(sections[0].notes[0].edited == day(2026, 10, 29))  // newest first
}

@Test func shortDates() {
    #expect(NoteDates.short(day(2026, 10, 28, 9), now: now, calendar: calendar).hasPrefix("9:05"))
    #expect(NoteDates.short(day(2026, 10, 25), now: now, calendar: calendar) == "Sunday")
    #expect(NoteDates.short(day(2026, 10, 21), now: now, calendar: calendar) == "10/21/26")
}

@Test func shortSources() {
    #expect(Note(kind: .app, target: "com.tinyspeck.slackmacgap/Acme/Alex Rivera (DM)", label: "Slack").shortSource
        == "Slack · Alex Rivera (DM)")
    #expect(Note(kind: .app, target: "com.apple.dt.Xcode", label: "Xcode").shortSource == "Xcode")
    #expect(Note(kind: .url, target: "chatgpt.com/c/123", label: "Whisper STT Explained").shortSource == "chatgpt.com")
    let alone = Note(kind: .url, target: "", label: "")  // a note without a source shows no source line
    #expect(alone.shortSource == "" && !alone.hasSource)
}

@Test func datesInNotesShowInTheChosenFormat() {
    #expect(DateStyle.format("2026-10-30", "dd/MM/yyyy") == "30/10/2026")
    #expect(DateStyle.format("2026-10-30", "MM/dd/yyyy") == "10/30/2026")
    #expect(DateStyle.format("2026-10-30", "dd.MM.y") == "30.10.2026")
    #expect(DateStyle.format("2026-10-30", "EEE, d MMM yyyy") == "Fri, 30 Oct 2026")
    #expect(DateStyle.format("2026-10-30", "d MMMM yyyy") == "30 October 2026")
    #expect(DateStyle.format("2026-10-30", "EEEE, d MMMM", thisYear: 2026) == "Friday, 30 October")
    #expect(DateStyle.format("2027-01-05", "EEEE, d MMMM", thisYear: 2026) == "Tuesday, 5 January 2027")
    UserDefaults.standard.set("dd/MM/yyyy", forKey: DateStyle.key)
    defer { UserDefaults.standard.removeObject(forKey: DateStyle.key) }
    var note = edited(now)
    note.text = "Printer\nCall them @2026-10-30, not @2026-02-30"
    #expect(note.preview == "Call them 30/10/2026, not @2026-02-30")
    #expect(note.dates.map(\.day) == ["2026-10-30"])  // the text itself keeps the ISO day
}
