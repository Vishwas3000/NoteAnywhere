import SwiftUI

/// What was edited when: month / week / day views over the daily snapshots.
struct CalendarView: View {
    enum Mode: String, CaseIterable { case month = "Month", week = "Week", day = "Day" }

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
        VStack(spacing: 0) {
            HStack {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button { step(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Previous")
                Button("Today") { date = Date() }
                Button { step(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Next")
                Text(title).font(.title3.bold()).lineLimit(1)
                Spacer()
                Picker("Show", selection: $filter) {
                    Text("All notes").tag("")
                    ForEach(sources, id: \.key) { Text($0.title).tag($0.key) }
                }
                .fixedSize()
            }
            .padding()
            Divider()
            switch mode {
            case .month: month(days)
            case .week: week(days)
            case .day: day(days)
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
        let today = cal.isDateInToday(d)
        return Button { open(d) } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(d.formatted(.dateTime.day()))
                    .font(.callout.weight(today ? .bold : .regular))
                    .foregroundStyle(today ? Color.white : .primary)
                    .padding(.horizontal, 5)
                    .background(today ? Color.accentColor : .clear, in: Capsule())
                ForEach(items.prefix(3)) { Text(firstLine($0.note)).font(.caption2).lineLimit(1) }
                if items.count > 3 {
                    Text("+\(items.count - 3) more").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .opacity(inMonth ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(Rectangle().stroke(.quaternary, lineWidth: 0.5))
        .accessibilityLabel("\(d.formatted(date: .complete, time: .omitted)), \(items.count) notes edited")
    }

    private func week(_ days: [String: [Snapshot]]) -> some View {
        let start = weekStart(date)
        return HStack(alignment: .top, spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                let d = cal.date(byAdding: .day, value: i, to: start)!
                VStack(alignment: .leading, spacing: 6) {
                    Button { open(d) } label: {
                        Text(d.formatted(.dateTime.weekday(.abbreviated).day())).font(.headline)
                            .foregroundStyle(cal.isDateInToday(d) ? Color.accentColor : .primary)
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
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .overlay(alignment: .trailing) { Divider() }
            }
        }
    }

    private func card(_ s: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(sourceName(s.note)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(firstLine(s.note)).font(.callout).lineLimit(2)
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func day(_ days: [String: [Snapshot]]) -> some View {
        let items = days[key(date)] ?? []
        if items.isEmpty {
            Text("Nothing edited on this day").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(items) { s in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(Date(timeIntervalSince1970: s.note.updatedAt / 1000).formatted(date: .omitted, time: .shortened))
                            .monospacedDigit()
                        Text(sourceName(s.note)).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    Text(s.note.text.isEmpty ? "Empty note" : s.note.text).textSelection(.enabled)
                }
                .padding(.vertical, 4)
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
    private var sources: [(key: String, title: String)] {
        var seen = Set<String>()
        return model.snapshots.reversed().compactMap { s -> (key: String, title: String)? in
            guard seen.insert(sourceKey(s.note)).inserted else { return nil }
            return (sourceKey(s.note), (s.note.kind == .app ? "App · " : "Site · ") + sourceName(s.note))
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
    private func sourceName(_ n: Note) -> String { n.kind == .app ? n.label : n.target }
    private func firstLine(_ n: Note) -> String {
        n.text.split(separator: "\n").first.map(String.init) ?? (n.kind == .app ? n.label : n.target)
    }
}
