import SwiftUI

/// Knowledge graph of all notes, like Obsidian's graph view.
struct GraphView: View {
    var body: some View {
        ContentUnavailableView("Graph", systemImage: "point.3.connected.trianglepath.dotted")
    }
}
