import SwiftUI

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
