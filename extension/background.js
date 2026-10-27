const HOST = "com.memorynotes.host";

// Content scripts can't talk to native hosts directly, so relay through here.
chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg.op === "save") msg.note.id ??= crypto.randomUUID();
  chrome.runtime.sendNativeMessage(HOST, msg, (reply) => {
    if (chrome.runtime.lastError) {
      sendResponse({ ok: false, error: "host-missing", detail: chrome.runtime.lastError.message });
    } else {
      sendResponse(reply ?? { ok: false, error: "empty reply" });
    }
  });
  return true; // keep sendResponse alive for the async reply
});

chrome.action.onClicked.addListener(async (tab) => {
  try {
    await chrome.tabs.sendMessage(tab.id, { type: "toggle" });
  } catch {
    // Tabs opened before install have no content script yet; activeTab lets us inject it now.
    // chrome:// and Web Store pages refuse injection, nothing to do there.
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: ["content.js"] }).catch(() => {});
    await chrome.tabs.sendMessage(tab.id, { type: "toggle" }).catch(() => {});
  }
});
