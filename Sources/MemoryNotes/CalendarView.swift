import AppKit
import SwiftUI

/// What was edited when: month / week / day views over the daily snapshots.
struct CalendarView: View {
    enum Mode: String, CaseIterable { case day = "Day", week = "Week", month = "Month" }

    @ObservedObject private var model = NotesModel.shared
    @State private var mode = Mode.month
    @State private var date = Date()
    @State private var filter = ""  // "" = all notes, else "kind:target"

    private let cal = Calendar.current

    private static let dayKey: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        let days = Dictionary(grouping: model.snapshots.filter { filter.isEmpty || sourceKey($0.note) == filter }, by: \.day)
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.largeTitle.bold()).lineLimit(1).padding([.horizontal, .top]).padding(.bottom, 8)
            Divider()
            if days.isEmpty {
                ContentUnavailableView("No Edits Yet", systemImage: "calendar",
                                       description: Text("Notes appear here on the days you edit them."))
            } else {
                switch mode {
                case .month: month(days)
                case .week: week(days)
                case .day: day(days)
                }
            }
        }
        .toolbar {
            // ⌘-arrows rather than bare arrows, so text fields keep their arrow keys.
            ToolbarItemGroup(placement: .navigation) {
                Button { step(-1) } label: { Label("Previous", systemImage: "chevron.left") }
                    .help("Previous \(mode.rawValue.lowercased()) (⌘←)")
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Today") { date = Date() }
                    .help("Go to today (⌘T)")
                    .keyboardShortcut("t", modifiers: .command)
                Button { step(1) } label: { Label("Next", systemImage: "chevron.right") }
                    .help("Next \(mode.rawValue.lowercased()) (⌘→)")
                    .keyboardShortcut(.rightArrow, modifiers: .command)
            }
            ToolbarItemGroup {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .help("Day, week or month")
                Picker(selection: $filter) {
                    Label("All Notes", systemImage: "tray.full").tag("")
                    Divider()
                    ForEach(sources, id: \.key) { source in
                        Label { Text(source.title) } icon: { menuIcon(source.note) }.tag(source.key)
                    }
                } label: {
                    Label("Show", systemImage: "line.3.horizontal.decrease.circle")
                }
                .pickerStyle(.menu)
                .help("Show notes from one app or site")
            }
        }
    }

    // MARK: Views

    private func month(_ days: [String: [Snapshot]]) -> some View {
        let start = weekStart(cal.dateInterval(of: .month, for: date)!.start)
        let symbols = cal.shortWeekdaySymbols
        let headers = Array(symbols[(cal.firstWeekday - 1)...] + symbols[..<(cal.firstWeekday - 1)])
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(headers, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity) }
            }
            .padding(.vertical, 4)
            // Always 6 rows so the grid doesn't jump in height between months.
            ForEach(0..<6, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        let d = cal.date(byAdding: .day, value: row * 7 + col, to: start)!
                        monthCell(d, days[key(d)] ?? [])
                    }
                }
            }
        }
    }

    private func monthCell(_ d: Date, _ items: [Snapshot]) -> some View {
        let inMonth = cal.isDate(d, equalTo: date, toGranularity: .month)
        return Button { open(d) } label: {
            VStack(alignment: .leading, spacing: 3) {
                dayNumber(d)
                ForEach(items.prefix(3)) { s in
                    Label { Text(s.note.title) } icon: { NoteIcon(note: s.note, size: 12) }
                        .font(.caption).lineLimit(1)
                }
                if items.count > 3 {
                    Text("\(items.count - 3) more").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(inMonth ? 1 : 0.35)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(Rectangle().stroke(.separator, lineWidth: 0.5))
        .accessibilityLabel("\(d.formatted(date: .complete, time: .omitted)), \(items.count) notes edited")
    }

    private func week(_ days: [String: [Snapshot]]) -> some View {
        let start = weekStart(date)
        let dates = (0..<7).map { cal.date(byAdding: .day, value: $0, to: start)! }
        return HStack(alignment: .top, spacing: 0) {
            ForEach(dates, id: \.self) { d in
                VStack(alignment: .leading, spacing: 8) {
                    Button { open(d) } label: {
                        HStack(spacing: 4) {
                            Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.callout).foregroundStyle(.secondary)
                            dayNumber(d)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open \(d.formatted(date: .complete, time: .omitted))")
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(days[key(d)] ?? []) { s in
                                Button { open(d) } label: { card(s) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .trailing) { Divider() }
            }
        }
        .overlay {
            if dates.allSatisfy({ days[key($0)] == nil }) {
                ContentUnavailableView("Nothing Edited This Week", systemImage: "calendar",
                                       description: Text("Notes you edit this week appear here."))
            }
        }
    }

    private func card(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(s.note.title).font(.callout.weight(.semibold)).lineLimit(2)
            if !s.note.preview.isEmpty {
                Text(s.note.preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 4) {
                NoteIcon(note: s.note, size: 12)
                Text(s.note.shortSource).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    /// The day of the month; today's sits in an accent circle, with dark text so it reads on the yellow in both modes.
    private func dayNumber(_ d: Date) -> some View {
        let today = cal.isDateInToday(d)
        return Text(d.formatted(.dateTime.day()))
            .font(.callout.weight(today ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(today ? Color.black : Color.primary)
            .frame(minWidth: 22, minHeight: 22)
            .background { if today { Circle().fill(.tint) } }
    }

    @ViewBuilder
    private func day(_ days: [String: [Snapshot]]) -> some View {
        let items = days[key(date)] ?? []
        if items.isEmpty {
            ContentUnavailableView("Nothing Edited", systemImage: "calendar",
                                   description: Text("Notes you edit on this day appear here."))
        } else {
            List(items) { s in
                Button { model.openRequest = s.note.id } label: {
                    NoteRow(note: s.note, date: s.note.edited.formatted(date: .omitted, time: .shortened))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the note")
            }
        }
    }

    // MARK: Helpers

    private var title: String {
        switch mode {
        case .month:
            return date.formatted(.dateTime.month(.wide).year())
        case .week:
            let start = weekStart(date), end = cal.date(byAdding: .day, value: 6, to: start)!
            return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day().year()))"
        case .day:
            return date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }

    /// One filter entry per app/site that has history; the newest label wins.
    private var sources: [(key: String, title: String, note: Note)] {
        var seen = Set<String>()
        return model.snapshots.reversed().compactMap { s -> (key: String, title: String, note: Note)? in
            guard seen.insert(sourceKey(s.note)).inserted else { return nil }
            return (sourceKey(s.note), s.note.hasSource ? s.note.source : "Notes Without a Source", s.note)
        }
        .sorted { $0.title < $1.title }
    }

    /// Menus draw only plain images, so the app/site icon goes in as a small NSImage rather than a NoteIcon view.
    private func menuIcon(_ note: Note) -> Image {
        guard let icon = IconStore.shared.icon(for: note)?.copy() as? NSImage else {
            return Image(systemName: note.kind == .app ? "app.dashed" : "globe")
        }
        icon.size = NSSize(width: 14, height: 14)
        return Image(nsImage: icon)
    }

    private func step(_ n: Int) {
        let unit: Calendar.Component = mode == .month ? .month : mode == .week ? .weekOfYear : .day
        date = cal.date(byAdding: unit, value: n, to: date) ?? date
    }

    private func open(_ d: Date) {
        date = d
        mode = .day
    }

    private func weekStart(_ d: Date) -> Date { cal.dateInterval(of: .weekOfYear, for: d)!.start }
    private func key(_ d: Date) -> String { Self.dayKey.string(from: d) }
    private func sourceKey(_ n: Note) -> String { n.kind.rawValue + ":" + n.target }
}
