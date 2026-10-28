import SwiftUI

/// What was edited when: month / week / day over the daily snapshots, like the Mac's calendar.
/// On the phone the month shows small icons per day, the week is an agenda, and a day lists its notes.
struct CalendarView: View {
    enum Mode: String, CaseIterable { case day = "Day", week = "Week", month = "Month" }

    @ObservedObject private var model = NotesModel.shared
    @AppStorage("calendarMode") private var mode = Mode.month
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
        NavigationStack {
            VStack(spacing: 0) {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.bottom, 8)
                switch mode {
                case .month: month(days)
                case .week: week(days)
                case .day: day(days)
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { filterMenu }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { step(-1) } label: { Label("Previous \(mode.rawValue)", systemImage: "chevron.left") }
                    Button("Today") { date = Date() }
                    Button { step(1) } label: { Label("Next \(mode.rawValue)", systemImage: "chevron.right") }
                }
            }
            .navigationDestination(for: String.self) { NoteDetailView(noteID: $0) }
        }
    }

    // MARK: Month

    private func month(_ days: [String: [Snapshot]]) -> some View {
        let start = weekStart(cal.dateInterval(of: .month, for: date)!.start)
        let symbols = cal.veryShortWeekdaySymbols
        let headers = Array(symbols[(cal.firstWeekday - 1)...] + symbols[..<(cal.firstWeekday - 1)])
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(headers.indices, id: \.self) { i in
                    Text(headers[i]).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .padding(.bottom, 4)
            .accessibilityHidden(true)
            // Always 6 rows so the grid doesn't jump in height between months.
            ForEach(0..<6, id: \.self) { row in
                Divider()
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        let d = cal.date(byAdding: .day, value: row * 7 + col, to: start)!
                        monthCell(d, days[key(d)] ?? [])
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func monthCell(_ d: Date, _ items: [Snapshot]) -> some View {
        let inMonth = cal.isDate(d, equalTo: date, toGranularity: .month)
        return Button { open(d) } label: {
            VStack(spacing: 5) {
                dayNumber(d)
                // Up to three notes as their site icon; the count says the rest.
                HStack(spacing: 2) {
                    ForEach(items.prefix(3)) { NoteIcon(note: $0.note, size: 11) }
                }
                if items.count > 3 {
                    Text("+\(items.count - 3)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .opacity(inMonth ? 1 : 0.35)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(d.formatted(date: .complete, time: .omitted)), ^[\(items.count) note](inflect: true) edited")
    }

    /// The day of the month; today's sits in an accent circle, with dark text so it reads on the yellow in both modes.
    private func dayNumber(_ d: Date) -> some View {
        let today = cal.isDateInToday(d)
        return Text(d.formatted(.dateTime.day()))
            .font(.callout.weight(today ? .bold : .regular))
            .monospacedDigit()
            .foregroundStyle(today ? Color.black : Color.primary)
            .frame(minWidth: 28, minHeight: 28)
            .background { if today { Circle().fill(.tint) } }
    }

    // MARK: Week and day

    private func week(_ days: [String: [Snapshot]]) -> some View {
        let start = weekStart(date)
        return List {
            ForEach(0..<7, id: \.self) { offset in
                let d = cal.date(byAdding: .day, value: offset, to: start)!
                let items = days[key(d)] ?? []
                Section {
                    if items.isEmpty {
                        Text("No edits").font(.subheadline).foregroundStyle(.tertiary)
                    }
                    ForEach(items) { s in row(s) }
                } header: {
                    Button { open(d) } label: {
                        HStack(spacing: 6) {
                            Text(d.formatted(.dateTime.weekday(.wide)))
                            dayNumber(d)
                        }
                        .font(.headline)
                        .foregroundStyle(Color.primary)
                    }
                    .buttonStyle(.plain)
                    .textCase(nil)
                    .accessibilityLabel("Open \(d.formatted(date: .complete, time: .omitted))")
                }
            }
        }
    }

    @ViewBuilder
    private func day(_ days: [String: [Snapshot]]) -> some View {
        let items = days[key(date)] ?? []
        if items.isEmpty {
            ContentUnavailableView("Nothing Edited", systemImage: "calendar",
                                   description: Text("Notes you edit on this day appear here."))
        } else {
            List(items) { row($0) }
        }
    }

    /// A day's version of a note; opens the note as it is now.
    private func row(_ s: Snapshot) -> some View {
        NavigationLink(value: s.note.id) {
            NoteRow(note: s.note, date: s.note.edited.formatted(date: .omitted, time: .shortened))
        }
    }

    // MARK: Helpers

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $filter) {
                Label("All Notes", systemImage: "tray.full").tag("")
                ForEach(sources, id: \.key) { source in
                    Text(source.title).tag(source.key)
                }
            }
        } label: {
            Label("Show", systemImage: filter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityHint("Shows notes from one app or site")
    }

    private var title: String {
        switch mode {
        case .month:
            return date.formatted(.dateTime.month(.wide).year())
        case .week:
            let start = weekStart(date), end = cal.date(byAdding: .day, value: 6, to: start)!
            return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
        case .day:
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
    }

    /// One filter entry per app/site that has history; the newest label wins.
    private var sources: [(key: String, title: String)] {
        var seen = Set<String>()
        return model.snapshots.reversed().compactMap { s -> (key: String, title: String)? in
            guard seen.insert(sourceKey(s.note)).inserted else { return nil }
            return (sourceKey(s.note), !s.note.hasSource ? "Notes Without a Source" : (s.note.kind == .app ? "App · " : "Site · ") + s.note.place)
        }
        .sorted { $0.title < $1.title }
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
