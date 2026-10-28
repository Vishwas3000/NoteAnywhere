import Carbon

/// System-wide hotkeys. Carbon hotkeys need no Accessibility permission and work whichever app is in front.
enum HotKeys {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef?] = []

    static func register(_ keyCode: Int, _ modifiers: Int, name: String, action: @escaping () -> Void) {
        if actions.isEmpty {
            // One handler for all hotkeys; the C callback can't capture, so it looks the action up by id.
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
                DispatchQueue.main.async { HotKeys.actions[id.id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let id = UInt32(actions.count + 1)
        actions[id] = action
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: OSType(0x4D4E5345), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { NSLog("MemoryNotes: \(name) is taken by another app (\(status))") }
        refs.append(ref)
    }
}
