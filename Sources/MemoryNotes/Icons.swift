import AppKit
import LinkPresentation
import SwiftUI

/// App icons come from the system. Website icons are fetched once from the site itself (no third-party favicon
/// service, so nobody else learns which sites you keep notes on) and cached in icons/<host>.png.
@MainActor
final class IconStore: ObservableObject {
    static let shared = IconStore()
    @Published private var icons: [String: NSImage] = [:]
    private var requested: Set<String> = []
    private let dir = NoteStore.root.appendingPathComponent("icons")

    func icon(for note: Note) -> NSImage? {
        let key = note.kind == .app ? note.target : String(note.target.prefix { $0 != "/" })
        if let icon = icons[key] { return icon }
        if requested.insert(key).inserted {
            Task { await load(note.kind, key) }  // async so the view body never publishes changes
        }
        return nil
    }

    private func load(_ kind: Note.Kind, _ key: String) async {
        if kind == .app {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) else { return }
            icons[key] = NSWorkspace.shared.icon(forFile: url.path)
            return
        }
        // The host becomes a file name, so keep it to host characters.
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || ".-:".contains($0) }) else { return }
        let file = dir.appendingPathComponent(key + ".png")
        if let image = NSImage(contentsOf: file) {
            icons[key] = image
            return
        }
        guard let image = await Self.fetch(host: key) else { return }  // not cached: retried next launch
        icons[key] = image
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? png.write(to: file, options: .atomic)
        }
    }

    private static func fetch(host: String) async -> NSImage? {
        guard let site = URL(string: "https://\(host)") else { return nil }
        let provider = LPMetadataProvider()
        provider.timeout = 10
        if let item = try? await provider.startFetchingMetadata(for: site).iconProvider,
           let image = await withCheckedContinuation({ (done: CheckedContinuation<NSImage?, Never>) in
               _ = item.loadObject(ofClass: NSImage.self) { object, _ in done.resume(returning: object as? NSImage) }
           }) {
            return image
        }
        // Sites without <link rel=icon> often still serve the classic favicon.
        guard let (data, _) = try? await URLSession.shared.data(from: site.appendingPathComponent("favicon.ico")),
              let image = NSImage(data: data), image.isValid else { return nil }
        return image
    }
}

/// The note's app icon or site favicon, with a symbol until it loads (or if there is none).
struct NoteIcon: View {
    let note: Note
    var size: CGFloat = 16
    @ObservedObject private var icons = IconStore.shared

    var body: some View {
        Group {
            if let image = icons.icon(for: note) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: note.kind == .app ? "app.dashed" : "globe").resizable().aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
