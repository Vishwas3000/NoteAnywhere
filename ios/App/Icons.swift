import LinkPresentation
import SwiftUI

/// Website icons, fetched once from the site itself (no third-party favicon service) and cached as PNG in the
/// icons table, like the Mac. App notes come from Mac apps, whose icons aren't on the phone, so they get a symbol.
@MainActor
final class IconStore: ObservableObject {
    static let shared = IconStore()
    @Published private var icons: [String: UIImage] = [:]
    private var requested: Set<String> = []

    func icon(for note: Note) -> UIImage? {
        guard note.kind == .url else { return nil }
        let key = String(note.target.prefix { $0 != "/" })
        if let icon = icons[key] { return icon }
        if requested.insert(key).inserted {
            Task { await load(key) }  // async so the view body never publishes changes
        }
        return nil
    }

    private func load(_ key: String) async {
        // The host goes into an https URL, so keep it to host characters.
        guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || ".-:".contains($0) }) else { return }
        if let png = NoteStore.icon(key), let image = UIImage(data: png) {
            icons[key] = image
            return
        }
        guard let image = await Self.fetch(host: key) else { return }  // not cached: retried next launch
        icons[key] = image
        if let png = image.pngData() { NoteStore.saveIcon(key, png: png) }
    }

    private static func fetch(host: String) async -> UIImage? {
        guard let site = URL(string: "https://\(host)") else { return nil }
        let provider = LPMetadataProvider()
        provider.timeout = 10
        if let item = try? await provider.startFetchingMetadata(for: site).iconProvider,
           let image = await withCheckedContinuation({ (done: CheckedContinuation<UIImage?, Never>) in
               _ = item.loadObject(ofClass: UIImage.self) { object, _ in done.resume(returning: object as? UIImage) }
           }) {
            return image
        }
        // Sites without <link rel=icon> often still serve the classic favicon.
        guard let (data, _) = try? await URLSession.shared.data(from: site.appendingPathComponent("favicon.ico")) else { return nil }
        return UIImage(data: data)
    }
}

/// The site's favicon, or a symbol: a Mac window for app notes, a note for notes with no place.
struct NoteIcon: View {
    let note: Note
    var size: CGFloat = 16
    @ObservedObject private var icons = IconStore.shared

    var body: some View {
        Group {
            if let image = icons.icon(for: note) {
                Image(uiImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
            } else {
                Image(systemName: note.kind == .app ? "macwindow" : note.hasSource ? "globe" : "note.text")
                    .resizable().aspectRatio(contentMode: .fit).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension Note {
    var pageURL: URL? { kind == .url && hasSource ? URL(string: "https://\(target)") : nil }
}
