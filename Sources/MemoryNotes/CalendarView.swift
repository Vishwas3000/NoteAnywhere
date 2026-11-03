import AppKit
import SwiftUI

/// What's planned and what was edited when: month / week / day views over the notes' dated lines (tasks first)
/// and their daily snapshots.
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
        let due = dueByDay()  // once per draw: it reads every note
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.largeTitle.bold()).lineLimit(1).padding([.horizontal, .top]).padding(.bottom, 8)
            Divider()
            if days.isEmpty && due.isEmpty {
                ContentUnavailableView("Nothing Here Yet", systemImage: "calendar", description: Text(
                    "Notes appear on the days you edit them. Type @today or @tomorrow in a note to put a line or task on a day."))
            } else {
                switch mode {
                case .month: month(days, due)
                case .week: week(days, due)
                case .day: day(days, due)
                }
            }
        }
        .background(TrackpadSwipe { step($0) })
        .onChange(of: model.calendarRequest, initial: true) { showRequestedDay() }
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

    private func month(_ days: [String: [Snapshot]], _ due: [String: [DatedLine]]) -> some View {
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
                        monthCell(d, days[key(d)] ?? [], planned: due[key(d)] ?? [])
                    }
                }
            }
        }
    }

    private func monthCell(_ d: Date, _ items: [Snapshot], planned: [DatedLine]) -> some View {
        let inMonth = cal.isDate(d, equalTo: date, toGranularity: .month)
        let edited = items.prefix(max(0, 3 - planned.count))
        let hidden = planned.count + items.count - min(planned.count, 3) - edited.count
        return Button { open(d) } label: {
            VStack(alignment: .leading, spacing: 3) {
                dayNumber(d)
                ForEach(planned.prefix(3)) { item in
                    Group {
                        if item.isRange {
                            rangeBar(item, d)
                        } else {  // a tinted pill, so planned days stand apart from notes merely edited that day
                            Label { Text(item.text).strikethrough(item.done) } icon: { checkbox(item) }
                                .font(.caption).lineLimit(1)
                                .foregroundStyle(item.done ? .secondary : .primary)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(color(item).opacity(0.3), in: RoundedRectangle(cornerRadius: 4))
                        }
                    }
                    .contextMenu { eventMenu(item) }
                }
                ForEach(edited) { s in
                    Label { Text(s.note.title) } icon: { NoteIcon(note: s.note, size: 12) }
                        .font(.caption).lineLimit(1)
                        .foregroundStyle(.secondary)
                }
                if hidden > 0 {
                    Text("\(hidden) more").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(inMonth ? 1 : 0.35)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Rectangle().stroke(.separator, lineWidth: 0.5))  // under the range strips, which run across it
        .accessibilityLabel("\(d.formatted(date: .complete, time: .omitted)), \(planned.count) planned, \(items.count) notes edited")
    }

    private func week(_ days: [String: [Snapshot]], _ due: [String: [DatedLine]]) -> some View {
        let start = weekStart(date)
        let dates = (0..<7).map { cal.date(byAdding: .day, value: $0, to: start)! }
        // Ranges touching the week go in rows shared by every column, so a strip lines up from day to day; one that
        // starts after a row's last range ends joins that row.
        var seen = Set<String>(), rows: [[DatedLine]] = []
        for range in dates.flatMap({ due[key($0)] ?? [] }).filter({ $0.isRange && seen.insert("\($0.noteID)/\($0.line)/\($0.first!)").inserted })
            .sorted(by: { ($0.first!, $1.last!) < ($1.first!, $0.last!) }) {
            if let i = rows.firstIndex(where: { $0.last!.last! < range.first! }) { rows[i].append(range) } else { rows.append([range]) }
        }
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
                    ForEach(rows.indices, id: \.self) { row in
                        if let item = rows[row].first(where: { ($0.first!...$0.last!).contains(key(d)) }) {
                            Button { model.openRequest = item.noteID } label: { rangeBar(item, d, inset: 8) }
                                .buttonStyle(.plain)
                                .accessibilityHint("Opens the note")
                                .contextMenu { eventMenu(item) }
                        } else {
                            rangeBar(rows[row][0], d, inset: 8).hidden()  // keeps the row, so the strips below stay level
                        }
                    }
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach((due[key(d)] ?? []).filter { !$0.isRange }) { plannedRow($0, compact: true) }
                            ForEach(days[key(d)] ?? []) { s in
                                Button { open(d) } label: { card(s) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(alignment: .trailing) { Divider() }  // under the range strips, which run across it
            }
        }
        .overlay {
            if dates.allSatisfy({ days[key($0)] == nil && due[key($0)] == nil }) {
                ContentUnavailableView("Nothing This Week", systemImage: "calendar",
                                       description: Text("Notes you edit or plan for this week appear here."))
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
    private func day(_ days: [String: [Snapshot]], _ due: [String: [DatedLine]]) -> some View {
        let items = days[key(date)] ?? [], planned = due[key(date)] ?? []
        if items.isEmpty && planned.isEmpty {
            ContentUnavailableView("Nothing on This Day", systemImage: "calendar",
                                   description: Text("Notes you edit on this day, and lines dated for it, appear here."))
        } else {
            List {
                if !planned.isEmpty {
                    Section("Planned") { ForEach(planned) { plannedRow($0, compact: false) } }
                }
                if !items.isEmpty {
                    Section("Edited") {
                        ForEach(items) { s in
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
            }
        }
    }

    // MARK: Planned (dated lines)

    /// Dated lines by day, for the notes the filter lets through.
    private func dueByDay() -> [String: [DatedLine]] {
        DatedLine.byDay(model.notes.filter { filter.isEmpty || sourceKey($0) == filter }.flatMap(\.dates))
    }

    private func color(_ item: DatedLine) -> Color {
        item.barColor(label: model.notes.first { $0.id == item.noteID }?.color).swatch
    }

    /// Right-click on an event: that event's own colour, written into its line of the note.
    private func eventMenu(_ item: DatedLine) -> some View {
        ColorLabelMenu(current: item.color) { model.setColor(item, $0) }
    }

    /// One day of a range: a tinted bar that runs into the next day's cell, rounded where the range starts and ends.
    /// The title shows on the first day and again where a week begins.
    private func rangeBar(_ item: DatedLine, _ d: Date, inset: CGFloat = 6) -> some View {
        let day = key(d), starts = day == item.first, ends = day == item.last
        let titled = starts || cal.component(.weekday, from: d) == cal.firstWeekday
        return Text(titled ? item.text : " ")
            .font(.caption.weight(.medium)).lineLimit(1)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = UnevenRoundedRectangle(topLeadingRadius: starts ? 4 : 0, bottomLeadingRadius: starts ? 4 : 0,
                                                   bottomTrailingRadius: ends ? 4 : 0, topTrailingRadius: ends ? 4 : 0)
                shape.fill(.background).overlay(shape.fill(color(item).opacity(0.3)))  // opaque, so no grid line shows through
            }
            .padding(.leading, starts ? 0 : -inset).padding(.trailing, ends ? 0 : -inset)  // over the cell's padding, to its edges
            .accessibilityLabel("\(item.text), \(span(item))")
    }

    /// "3 Dec – 6 Dec" in the date format chosen in Settings.
    private func span(_ item: DatedLine) -> String {
        "\(DateStyle.format(item.first ?? item.day)) – \(DateStyle.format(item.last ?? item.day))"
    }

    /// A tickable box for tasks (it edits the note's checklist), a calendar glyph for other dated lines.
    @ViewBuilder
    private func checkbox(_ item: DatedLine) -> some View {
        if item.isTask {
            Button { model.toggleTask(item) } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.done ? Color.notesAccent : color(item))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(item.done ? "Done" : "Not done")
            .accessibilityHint("Ticks the task in its note")
        } else {
            Image(systemName: "calendar").foregroundStyle(color(item)).accessibilityHidden(true)
        }
    }

    private func plannedRow(_ item: DatedLine, compact: Bool) -> some View {
        let note = model.notes.first { $0.id == item.noteID }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            checkbox(item)
            Button { model.openRequest = item.noteID } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.text).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary)
                        .font(compact ? .callout : .body).lineLimit(compact ? 3 : nil)
                    if item.isRange {
                        Text(span(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let note, note.title != item.text {
                        Text(note.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the note")
        }
        .padding(compact ? 8 : 2)
        .background { if compact { RoundedRectangle(cornerRadius: 8).fill(color(item).opacity(0.25)) } }
        .contextMenu { eventMenu(item) }
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

    /// ⌘-clicked dates arrive here (via NotesWindow switching to the calendar).
    private func showRequestedDay() {
        guard let day = model.calendarRequest, let d = Self.dayKey.date(from: day) else { return }
        date = d
        mode = .day
        model.calendarRequest = nil
    }

    private func open(_ d: Date) {
        date = d
        mode = .day
    }

    private func weekStart(_ d: Date) -> Date { cal.dateInterval(of: .weekOfYear, for: d)!.start }
    private func key(_ d: Date) -> String { Self.dayKey.string(from: d) }
    private func sourceKey(_ n: Note) -> String { n.kind.rawValue + ":" + n.target }
}

/// A two-finger sideways swipe on the trackpad over the calendar: fingers left = next, right = previous, one step per
/// swipe (D68). SwiftUI has no trackpad swipe on the Mac, so this watches scroll events and lets them through.
struct TrackpadSwipe: NSViewRepresentable {
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> NSView { context.coordinator.view }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.onSwipe = onSwipe }
    func makeCoordinator() -> Coordinator { Coordinator(onSwipe) }

    /// Which way a swipe that has moved the fingers this far goes, or nil while it's too short or mostly vertical.
    static func step(dx: CGFloat, dy: CGFloat) -> Int? {
        abs(dx) > 40 && abs(dx) > 2 * abs(dy) ? (dx < 0 ? 1 : -1) : nil
    }

    final class Coordinator {
        let view = NSView()
        var onSwipe: (Int) -> Void
        private var monitor: Any?
        private var dx: CGFloat = 0, dy: CGFloat = 0, done = false

        init(_ onSwipe: @escaping (Int) -> Void) {
            self.onSwipe = onSwipe
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handle(event)
                return event
            }
        }
        deinit { monitor.map(NSEvent.removeMonitor) }

        private func handle(_ event: NSEvent) {
            // Trackpad only (a mouse wheel has no phase), and not the coasting after the fingers lift.
            guard !event.phase.isEmpty, event.momentumPhase.isEmpty, event.window == view.window,
                  view.bounds.contains(view.convert(event.locationInWindow, from: nil)) else { return }
            if event.phase == .began { (dx, dy, done) = (0, 0, false) }
            // The fingers' own direction, whatever the natural-scrolling setting.
            let flip: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            dx += event.scrollingDeltaX * flip
            dy += event.scrollingDeltaY * flip
            if !done, let n = TrackpadSwipe.step(dx: dx, dy: dy) {
                done = true
                onSwipe(n)
            }
        }
    }
}
