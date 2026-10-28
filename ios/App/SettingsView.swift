import SwiftUI

struct SettingsView: View {
    @ObservedObject private var model = NotesModel.shared
    @ObservedObject private var sync = CloudSync.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // SyncSettingsView is a Form of its own (shared with the Mac), so it gets its own page.
                    NavigationLink {
                        SyncSettingsView().navigationTitle("Sync")
                    } label: {
                        LabeledContent {
                            Text(syncStatus)
                        } label: {
                            Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                } footer: {
                    Text("Keep notes in step with MemoryNotes on your Mac.")
                }

                Section {
                    LabeledContent("Search Model", value: SearchIndex.hasModel ? "Downloaded" : "Not Yet Downloaded")
                    LabeledContent("Apple Intelligence", value: Assistant.unavailableReason == nil ? "Ready" : "Not Available")
                } header: {
                    Text("On This iPhone")
                } footer: {
                    Text(Assistant.unavailableReason.map { "Search finds notes by meaning with a small on-device model (about 90 MB), downloaded on your first search. \($0)" }
                         ?? "Search finds notes by meaning with a small on-device model (about 90 MB), downloaded on your first search. ✨ in a note rewrites text on this iPhone; nothing leaves it.")
                }

                Section {
                    Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                } header: {
                    Text("Safari")
                } footer: {
                    Text("To see page notes on websites, turn on MemoryNotes in Settings › Apps › Safari › Extensions, then allow it on the sites you want.")
                }

                Section {
                    LabeledContent("Notes", value: model.notes.count.formatted())
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var syncStatus: String {
        switch sync.mode {
        case .off, .icloud: "Off"
        case .cloud: sync.email == nil ? "Not Signed In" : "On"
        }
    }
}
