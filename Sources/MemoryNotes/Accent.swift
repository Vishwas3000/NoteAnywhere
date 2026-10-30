import SwiftUI

extension NoteColor {
    var title: String { rawValue.capitalized }
    var swatch: Color {
        switch self {
        case .grey: .gray
        case .blue: .blue
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        case .pink: .pink
        case .purple: .purple
        case .cyan: .cyan
        case .orange: .orange
        }
    }
}

extension Color {
    /// Apple Notes' warm yellow, same values as the editor CSS: darker in light mode so text drawn in it stays legible.
    static let notesAccent: Color = {
        let dark = (red: 1.0, green: 0.84, blue: 0.04), light = (red: 0.78, green: 0.54, blue: 0.0)
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
        })
        #else
        return Color(uiColor: UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.red, green: c.green, blue: c.blue, alpha: 1)
        })
        #endif
    }()
}

extension DatedLine {
    /// A range's colour in the calendar: its note's label, else one of its own picked from the line, so it stays the
    /// same between launches and two events side by side usually differ.
    func barColor(label: NoteColor?) -> NoteColor {
        if let label { return label }
        let auto: [NoteColor] = [.blue, .green, .purple, .orange, .cyan, .red]  // not pink: too close to purple when tinted
        let seed = "\(noteID)/\(line)".unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFFFF }
        return auto[seed % auto.count]
    }
}
