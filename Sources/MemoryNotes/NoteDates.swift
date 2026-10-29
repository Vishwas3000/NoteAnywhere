import Foundation
import SwiftUI

extension Note {
    /// "Slack · Alex Rivera (DM)" or "chatgpt.com": the app with its narrowest place, or the site's host.
    var shortSource: String {
        if kind == .url { return String(target.prefix { $0 != "/" }) }
        let parts = target.split(separator: "/")
        return parts.count > 1 ? "\(label) · \(parts.last!)" : label
    }
}

/// Apple Notes' date wording; `now` and `calendar` are parameters so tests can pin them.
enum NoteDates {
    struct Section: Identifiable {
        let title: String
        var notes: [Note]
        var id: String { title }
    }

    /// Sidebar sections, newest edit first: Today, Yesterday, Previous 7 Days, Previous 30 Days, then "October 2026".
    static func sections(_ notes: [Note], now: Date = .now, calendar: Calendar = .current) -> [Section] {
        var sections: [Section] = []
        for note in notes.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            let title = switch days(note.edited, before: now, calendar) {
            case ...0: "Today"
            case 1: "Yesterday"
            case ...7: "Previous 7 Days"
            case ...30: "Previous 30 Days"
            default: note.edited.formatted(style(calendar).month(.wide).year())
            }
            if sections.last?.title == title {
                sections[sections.count - 1].notes.append(note)
            } else {
                sections.append(Section(title: title, notes: [note]))
            }
        }
        return sections
    }

    /// A row's date: the time today, the weekday within the past week, otherwise a short date.
    static func short(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        switch days(date, before: now, calendar) {
        case ...0: date.formatted(style(calendar).hour().minute())
        case ...6: date.formatted(style(calendar).weekday(.wide))
        default: date.formatted(style(calendar).day().month(.defaultDigits).year(.twoDigits))
        }
    }

    /// Calendar days between the two dates; edits from the future (clock changes) count as today.
    private static func days(_ date: Date, before now: Date, _ calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    }

    private static func style(_ calendar: Calendar) -> Date.FormatStyle {
        Date.FormatStyle(locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
    }
}

/// Settings ▸ "Dates in notes" (Mac and iPhone).
struct DateFormatPicker: View {
    @AppStorage(DateStyle.key) private var choice = ""

    var body: some View {
        Picker("Dates in notes", selection: $choice) {
            ForEach(DateStyle.choices, id: \.self) { pattern in
                let example = DateStyle.format("2026-10-30", pattern.isEmpty ? DateStyle.region : pattern)
                Text(pattern.isEmpty ? "Automatic (\(example))" : "\(example)  ·  \(Self.order[pattern] ?? "")").tag(pattern)
            }
        }
    }

    private static let order = ["dd/MM/yyyy": "Day/Month/Year", "MM/dd/yyyy": "Month/Day/Year", "yyyy-MM-dd": "Year-Month-Day"]
}
