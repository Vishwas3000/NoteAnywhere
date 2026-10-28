import SwiftUI

@main
struct MemoryNotesApp: App {
    @Environment(\.scenePhase) private var phase

    init() {
        #if DEBUG
        if CommandLine.arguments.contains("-seedSampleNotes") { SampleNotes.seed() }
        #endif
        _ = CloudSync.shared  // starts syncing if it's turned on
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in Task { await CloudSync.shared.handle(url) } }  // sign-in links
        }
        .onChange(of: phase) {
            guard phase == .active else { return }
            NotesModel.shared.reload()  // the Share and Safari extensions may have saved while we were away
            CloudSync.shared.syncNow()
        }
    }
}

enum AppTab: String { case notes, calendar, graph, settings }

/// Tabs on iPhone; `.sidebarAdaptable` turns them into a sidebar on iPad.
struct RootView: View {
    @AppStorage("tab") private var tab = AppTab.notes
    @ObservedObject private var model = NotesModel.shared

    var body: some View {
        TabView(selection: $tab) {
            Tab("Notes", systemImage: "note.text", value: .notes) { NotesListView() }
            Tab("Calendar", systemImage: "calendar", value: .calendar) { CalendarView() }
            Tab("Graph", systemImage: "point.3.connected.trianglepath.dotted", value: .graph) { GraphView() }
            Tab("Settings", systemImage: "gearshape", value: .settings) { SettingsView() }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(.notesAccent)
        .onChange(of: model.searchRequest) { if model.searchRequest != nil { tab = .notes } }
        .onChange(of: model.calendarRequest) { if model.calendarRequest != nil { tab = .calendar } }  // CalendarView takes it from there
    }
}
