const HOST = "com.memorynotes.host";
const api = globalThis.browser ?? chrome; // promise-returning in every browser
let watcher, pending;
// Firefox passes the panel's frame (an extension page inside a web page) no messages, so each panel there keeps a port
// open, and what's meant for a tab's panel goes down its port (overlay.js).
const panels = new Map();
chrome.runtime.onConnect.addListener((port) => {
  if (port.name !== "panel") return;
  const tab = port.sender?.tab?.id;
  panels.set(tab, port);
  port.onDisconnect.addListener(() => { if (panels.get(tab) === port) panels.delete(tab); });
});

// One long-lived host process reports every save (from the app or any tab), so open overlays update live.
// An open native port also keeps this service worker alive.
function watch() {
  if (watcher) return;
  watcher = chrome.runtime.connectNative(HOST);
  watcher.onMessage.addListener((msg) => {
    if (msg.event !== "changed") return;
    clearTimeout(pending); // the app saves on every keystroke; tell the overlays once things settle
    pending = setTimeout(() => {
      chrome.runtime.sendMessage({ type: "mn:changed" }).catch(() => {});
      panels.forEach((port) => port.postMessage({ type: "mn:changed" }));
    }, 250);
  });
  watcher.onDisconnect.addListener(() => { void chrome.runtime.lastError; watcher = null; });
  watcher.postMessage({ op: "watch" });
}

chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  // The overlay frame asks which tab it lives in, so it only listens to its own tab's content script.
  if (msg.type === "mn:whoami") sendResponse(sender.tab?.id);
  else if (msg.type === "mn:watch") watch();
  else if (msg.type === "mn:panel") panels.get(sender.tab?.id)?.postMessage(msg.message); // from content.js, in Firefox
  // Calls the panel's frame can't make itself in Firefox and Safari (overlay.js, "relayed").
  else if (msg.type === "mn:relay") {
    api.tabs.sendMessage(msg.tabId ?? sender.tab?.id, msg.message, msg.options).then(sendResponse, () => sendResponse(undefined));
    return true;
  } else if (msg.type === "mn:native") {
    // Safari ignores the host name and always asks the containing app's extension handler.
    api.runtime.sendNativeMessage(HOST, msg.message).then(sendResponse, () => sendResponse(undefined));
    return true;
  }
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
