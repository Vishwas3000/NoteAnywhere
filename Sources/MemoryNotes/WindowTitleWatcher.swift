import AppKit
import ApplicationServices

/// Follows one app's front-window title through Accessibility notifications (no polling).
/// Without the Accessibility permission it reports nil and notes stay app-level.
final class WindowTitleWatcher {
    /// The front window's title, the open conversation for apps listed in `WindowContext.conversationHeaders`, and in a
    /// browser the open page as a website note's target (nil when the address bar can't be read).
    var onChange: (_ title: String?, _ conversation: String?, _ page: String?) -> Void = { _, _, _ in }
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var headerID: String?
    private var isBrowser = false
    private var poll: Timer?

    /// Shows the system prompt the first time; afterwards the user toggles NoteAnywhere in Privacy & Security ▸ Accessibility.
    static func requestPermission() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    func watch(_ app: NSRunningApplication?) {
        stop()
        guard let app, AXIsProcessTrusted() else { return onChange(nil, nil, nil) }
        headerID = app.bundleIdentifier.flatMap { WindowContext.conversationHeaders[$0] }
        isBrowser = app.bundleIdentifier.map(WindowContext.browsers.contains) ?? false
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.5)  // a hung app must not stall our main thread
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<WindowTitleWatcher>.fromOpaque(refcon).takeUnretainedValue().emit()
        }
        guard AXObserverCreate(app.processIdentifier, callback, &created) == .success, let created else { return onChange(nil, nil, nil) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()  // the watcher lives as long as NotesModel
        // Registered on the app element, these fire for all of its windows.
        for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXTitleChangedNotification] {
            AXObserverAddNotification(created, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        appElement = element
        if headerID != nil {
            // Switching chats changes no title and posts no notification we can observe, so look once a second
            // while such an app is in front. NotesModel ignores repeats.
            poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.emit() }
        }
        emit()
    }

    private func stop() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
        appElement = nil
        poll?.invalidate()
        poll = nil
        headerID = nil
        isBrowser = false
    }

    private func emit() {
        guard let window = frontWindow() else { return onChange(nil, nil, nil) }
        var page: String?
        if isBrowser, let bar = textField(in: window, inToolbar: false, depth: 0) {
            // While an address or a search is being typed, the place hasn't changed yet; the title changes once it opens.
            if Self.value(bar, kAXFocusedAttribute) as? Bool == true { return }
            page = WindowContext.page(addressBar: Self.string(bar, kAXValueAttribute) ?? "")
        }
        onChange(Self.string(window, kAXTitleAttribute), headerID.flatMap { find($0, in: window, depth: 0) }, page)
    }

    /// The browser's address bar: the text field in the window's toolbar (about 10 ms in Brave with a few tabs).
    private func textField(in element: AXUIElement, inToolbar: Bool, depth: Int) -> AXUIElement? {
        let role = Self.string(element, kAXRoleAttribute)
        if inToolbar, role == kAXTextFieldRole { return element }
        guard depth < 16, role != kAXRadioButtonRole else { return nil }  // tabs are radio buttons, hundreds of them
        for child in (Self.value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            if let found = textField(in: child, inToolbar: inToolbar || role == kAXToolbarRole, depth: depth + 1) { return found }
        }
        return nil
    }

    private func frontWindow() -> AXUIElement? {
        guard let appElement else { return nil }
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return (window as! AXUIElement)
    }

    /// Depth-first search for the element with this identifier; returns its description. Message lists are skipped:
    /// they're big, and their contents are none of our business.
    private func find(_ identifier: String, in element: AXUIElement, depth: Int) -> String? {
        if Self.string(element, kAXIdentifierAttribute) == identifier { return Self.string(element, kAXDescriptionAttribute) }
        guard depth < 8, Self.string(element, kAXRoleAttribute) != kAXTableRole else { return nil }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in (children as? [AXUIElement]) ?? [] {
            if let id = Self.string(child, kAXIdentifierAttribute), id.hasSuffix("TableView") || id.hasPrefix("ChatListView") { continue }
            if let found = find(identifier, in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value
    }
}
