import WebKit

/// Serves a note's images (D53) to the editor's web view: `noteimage:<id>` from the images folder.
final class ImageScheme: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let image = NoteStore.image(String(url.absoluteString.dropFirst(NoteStore.imageScheme.count + 1))) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))  // unknown, or not synced to this device yet
        }
        task.didReceive(URLResponse(url: url, mimeType: image.type, expectedContentLength: image.data.count, textEncodingName: nil))
        task.didReceive(image.data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
