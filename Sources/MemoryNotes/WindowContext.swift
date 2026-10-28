import Foundation

/// Turns a front window's title into a context path inside its app, broad to narrow:
/// "Alex Rivera (DM) - Acme - 8 new items - Slack" → ["Acme", "Alex Rivera (DM)"].
/// App notes target "bundle.id/Acme/Alex Rivera (DM)", so like web pages a parent context sees its children's notes.
enum WindowContext {
    static func path(title: String?, appName: String) -> [String] {
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return [] }
        var parts = title.split(separator: #/\s[-—–|]\s/#).map { clean(String($0)) }
        let app = appName.lowercased()
        // The app's own name ("Slack", "Brave" for "Brave Browser", "Visual Studio Code" for "Code") marks which end
        // of the title is the broad one.
        let isApp = { (part: String) in
            let part = part.lowercased()
            return !part.isEmpty && (app.hasPrefix(part) || part.hasPrefix(app) || part.hasSuffix(" " + app))
        }
        var broadFirst = true
        if parts.count == 1, isApp(parts[0]) {
            return []  // "WhatsApp": the title names only the app
        } else if let last = parts.last, parts.count > 1, isApp(last) {
            parts.removeLast()
            broadFirst = false  // "narrow - broad - App"
        } else if let first = parts.first, parts.count > 1, isApp(first) {
            parts.removeFirst()
        }
        parts.removeAll { $0.isEmpty || $0.contains(#/^(\d+\s+(new\s+items?|unread.*|notifications?|messages?)|edited)$/#.ignoresCase()) }
        if !broadFirst { parts.reverse() }
        return parts.map { $0.replacingOccurrences(of: "/", with: "∕") }  // "/" separates levels in the target
    }

    /// `conversation` is the open chat read from inside the window, for apps whose title never names it.
    static func target(bundleID: String, appName: String, title: String?, conversation: String? = nil) -> String {
        var path = path(title: title, appName: appName)
        if path.isEmpty, let conversation = conversation.map(clean), !conversation.isEmpty {
            path = [conversation.replacingOccurrences(of: "/", with: "∕")]
        }
        return ([bundleID] + path).joined(separator: "/")
    }

    /// Apps whose window title is only the app name, and the accessibility identifier of the element whose
    /// description names the open conversation. shortcut: one entry per app; add apps here as they come up.
    static let conversationHeaders = ["net.whatsapp.WhatsApp": "NavigationBar_HeaderViewButton"]

    /// Drops what changes without the place changing: unsaved dots, unread counts like "(3) Inbox" / "Inbox (3)".
    private static func clean(_ part: String) -> String {
        part.filter { !("\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}".contains($0)) }  // bidi marks (WhatsApp)
            .replacing(#/^[●•*]\s*/#, with: "")
            .replacing(#/^\(\d+\)\s*/#, with: "")
            .replacing(#/\s*\(\d+\)$/#, with: "")
            .trimmingCharacters(in: .whitespaces)
    }
}

extension Note {
    /// App notes: "Slack › Acme › Alex Rivera (DM)". Website notes: host plus the cleaned page title,
    /// "app.slack.com › Acme › Alex Rivera (DM)", or the address when there's no title.
    var place: String {
        if kind == .app {
            return ([label] + target.split(separator: "/").dropFirst().map(String.init)).joined(separator: " › ")
        }
        let host = String(target.prefix { $0 != "/" })
        let site = host.split(separator: ".").dropLast().last.map(String.init) ?? host  // "slack" in app.slack.com
        let title = WindowContext.path(title: label, appName: site)
        return label.isEmpty || label == target || title.isEmpty ? target : ([host] + title).joined(separator: " › ")
    }
}
