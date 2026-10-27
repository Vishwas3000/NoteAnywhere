chrome.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  // The overlay frame asks which tab it lives in, so it only listens to its own tab's content script.
  if (msg.type === "mn:whoami") sendResponse(sender.tab?.id);
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
