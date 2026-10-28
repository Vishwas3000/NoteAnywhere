const HOST = "com.memorynotes.host";
let watcher, pending;

// One long-lived host process reports every save (from the app or any tab), so open overlays update live.
// An open native port also keeps this service worker alive.
function watch() {
  if (watcher) return;
  watcher = chrome.runtime.connectNative(HOST);
  watcher.onMessage.addListener((msg) => {
    if (msg.event !== "changed") return;
    clearTimeout(pending); // the app saves on every keystroke; tell the overlays once things settle
    pending = setTimeout(() => chrome.runtime.sendMessage({ type: "mn:changed" }).catch(() => {}), 250);
  });
  watcher.onDisconnect.addListener(() => { void chrome.runtime.lastError; watcher = null; });
  watcher.postMessage({ op: "watch" });
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  // The overlay frame asks which tab it lives in, so it only listens to its own tab's content script.
  if (msg.type === "mn:whoami") sendResponse(sender.tab?.id);
  else if (msg.type === "mn:watch") watch();
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
