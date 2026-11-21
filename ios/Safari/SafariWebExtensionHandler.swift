import SafariServices

/// Answers the extension's `runtime.sendNativeMessage` in Safari, on iPhone and on the Mac, with the handler the Chrome
/// and Firefox host uses (`NativeHost.handle`), on the app's own database: through the App Group on iPhone, through a
/// sandbox exception on the Mac (D82).
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let message = (context.inputItems.first as? NSExtensionItem)?.userInfo?[SFExtensionMessageKey]
        var reply: Any = ["ok": false, "error": "NoteAnywhere couldn't read the request"]
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
