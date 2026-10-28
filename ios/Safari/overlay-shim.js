// Safari only. Safari runs the overlay's extension frame in the page's web process, where tabs.sendMessage is
// refused (the page's process gets killed) and native messaging isn't offered. The build points overlay.js's calls
// at these, and the background page makes them (background-shim.js).
const mnRelay = (msg) => chrome.runtime.sendMessage(msg);
function mnTabsSendMessage(tabId, message, options) {
  return mnRelay({ type: "mn:relay", tabId, message, options });
}
function mnSendNativeMessage(_app, message, callback) {
  mnRelay({ type: "mn:native", message }).then(callback, () => callback(undefined));
}
