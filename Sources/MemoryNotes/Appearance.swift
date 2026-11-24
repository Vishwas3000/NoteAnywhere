import AppKit
import SwiftUI

/// Settings ▸ General ▸ Appearance: follow the Mac (Automatic), or always Light or Dark (D85). The app's appearance
/// reaches every window, the floating panel, the search popup and the notes' web views (their prefers-color-scheme).
enum Appearance: String, CaseIterable {
    case automatic, light, dark
    static let key = "appearance"

    var name: NSAppearance.Name? {
        switch self {
        case .automatic: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }

    static var saved: Appearance { Appearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .automatic }

    @MainActor static func apply(_ choice: Appearance = saved) {
        NSApp.appearance = choice.name.flatMap(NSAppearance.init(named:))
    }
}

struct AppearancePicker: View {
    @AppStorage(Appearance.key) private var choice = Appearance.automatic

    var body: some View {
        Picker(selection: $choice) {
            Text("Automatic").tag(Appearance.automatic)
            Text("Light").tag(Appearance.light)
            Text("Dark").tag(Appearance.dark)
        } label: {
            Text("Appearance")
            Text("Automatic follows your Mac's Light or Dark setting.")
        }
        .onChange(of: choice) { _, value in Appearance.apply(value) }
    }
}
