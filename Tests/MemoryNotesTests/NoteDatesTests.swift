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
