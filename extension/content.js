// Places the overlay frame and tells it about the page. The UI itself lives in overlay.html, isolated from the page.
if (window.top === window && !window.__memoryNotes) (() => {
  window.__memoryNotes = true; // background.js may inject this again into tabs opened before install
  const host = () => location.host.replace(/^www\./, "");
  const page = () => ({
    url: host() + location.pathname,
    host: host(),
    page: location.pathname === "/" ? host() : host() + location.pathname.replace(/\/$/, ""),
    title: document.title,
  });
  let openOnReady = false;

  const frame = document.createElement("iframe");
  frame.src = chrome.runtime.getURL("overlay.html");
  frame.title = "MemoryNotes";
  frame.style.cssText = "all: initial; position: fixed; top: 8px; right: 8px; width: 336px; height: 0; border: 0;" +
    "z-index: 2147483647; display: none; color-scheme: normal;";
  document.documentElement.append(frame);

  const tell = (type, extra) => chrome.runtime.sendMessage({ type, ...extra }).catch(() => {});

  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg.type === "toggle") {
      openOnReady = true; // the frame may still be loading when the icon/shortcut is used
      tell("mn:toggle");
    } else if (msg.type === "mn:ready") {
      sendResponse({ ...page(), open: openOnReady });
    } else if (msg.type === "mn:frame") {
      frame.style.display = msg.visible ? "block" : "none";
      frame.style.height = `${Math.min(msg.height, innerHeight - 16)}px`;
    }
  });

  document.addEventListener("visibilitychange", () => { if (!document.hidden) tell("mn:context", { nav: false, page: page() }); });

  // shortcut: polling for SPA navigation, upgrade to the Navigation API if CPU matters.
  let lastUrl = page().url;
  setInterval(() => {
    if (page().url === lastUrl) return;
    lastUrl = page().url;
    tell("mn:context", { nav: true, page: page() });
  }, 1000);
})();
