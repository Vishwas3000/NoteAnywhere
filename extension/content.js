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
  // The frosted glass lives here: a backdrop-filter inside the cross-origin frame can't see the page behind it.
  frame.style.cssText = "all: initial; position: fixed; top: 8px; right: 8px; width: 340px; height: 0; border: 0;" +
    "z-index: 2147483647; display: none; color-scheme: normal; border-radius: 14px;" +
    "backdrop-filter: blur(24px) saturate(180%); -webkit-backdrop-filter: blur(24px) saturate(180%);" +
    "box-shadow: 0 0 0 .5px rgba(0,0,0,.06), 0 2px 6px rgba(0,0,0,.08), 0 12px 32px rgba(0,0,0,.18);";
  document.documentElement.append(frame);

  const tell = (type, extra) => chrome.runtime.sendMessage({ type, ...extra }).catch(() => {});
  const calm = matchMedia("(prefers-reduced-motion: reduce)");
  frame.addEventListener("transitionend", () => { frame.style.transition = "none"; });

  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg.type === "toggle") {
      openOnReady = true; // the frame may still be loading when the icon/shortcut is used
      tell("mn:toggle");
    } else if (msg.type === "mn:ready") {
      sendResponse({ ...page(), open: openOnReady });
    } else if (msg.type === "mn:frame") {
      const width = `${msg.width || 340}px`;
      // Animate only the expand/shrink; content-driven height changes (typing) must follow at once.
      if (frame.style.width !== width && frame.style.display !== "none" && msg.visible && !calm.matches) {
        frame.style.transition = "width .25s ease, height .25s ease";
      }
      frame.style.display = msg.visible ? "block" : "none";
      frame.style.width = width;
      frame.style.height = `${Math.min(msg.height, innerHeight - 16)}px`;
      sendResponse(innerHeight); // the frame can't see the page's viewport; it caps the panel and note heights with this
    }
  });

  addEventListener("resize", () => { if (frame.style.display !== "none") tell("mn:resize"); });
  document.addEventListener("visibilitychange", () => { if (!document.hidden) tell("mn:context", { nav: false, page: page() }); });

  // shortcut: polling for SPA navigation, upgrade to the Navigation API if CPU matters.
  let lastUrl = page().url;
  setInterval(() => {
    if (page().url === lastUrl) return;
    lastUrl = page().url;
    tell("mn:context", { nav: true, page: page() });
  }, 1000);
})();
