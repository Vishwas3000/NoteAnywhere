import SafariServices

/// Answers the extension's `runtime.sendNativeMessage` with the same handler as the Mac's native host
/// (list, save, search, delete, ai), on the database the app shares through the App Group.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let message = (context.inputItems.first as? NSExtensionItem)?.userInfo?[SFExtensionMessageKey]
        var reply: Any = ["ok": false, "error": "MemoryNotes couldn't read the request"]
        if (message as? [String: Any])?["op"] as? String == "watch" {
            // watch streams events on a native port, which Safari on iOS doesn't route to this handler.
            reply = ["ok": false, "error": "watch isn't available in Safari"]
        } else if let message, JSONSerialization.isValidJSONObject(message),
                  let request = try? JSONSerialization.data(withJSONObject: message),
                  let json = try? JSONEncoder().encode(NativeHost.handle(request)),
                  let object = try? JSONSerialization.jsonObject(with: json) {
            reply = object
        }
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response])
    }
}
