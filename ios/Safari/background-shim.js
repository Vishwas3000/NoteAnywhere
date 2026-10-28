// Safari only: makes the calls the overlay frame hands over (see overlay-shim.js).
chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  if (msg.type === "mn:relay") {
    const tabId = msg.tabId ?? sender.tab?.id;
    browser.tabs.sendMessage(tabId, msg.message, msg.options).then(sendResponse, () => sendResponse(undefined));
    return true;
  }
  if (msg.type === "mn:native") {
    // Safari ignores the app id and always asks this app's SafariWebExtensionHandler.
    browser.runtime.sendNativeMessage("com.memorynotes.ios", msg.message)
      .then(sendResponse, (e) => sendResponse({ ok: false, error: `MemoryNotes didn't answer: ${e?.message ?? e}` }));
    return true;
  }
});
