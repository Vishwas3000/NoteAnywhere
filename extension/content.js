// Places the overlay frame and tells it about the page. The UI itself lives in overlay.html, isolated from the page.
if (window.top === window && !window.__memoryNotes) (() => {
  window.__memoryNotes = true; // background.js may inject this again into tabs opened before install
  const host = () => location.host.replace(/^www\./, "");
  // Sites whose address names the page after "?": a YouTube video or search, a Google search (D70). Mirrors
  // Note.pageTarget in the Mac app.
  const queryName = (h, path) => h === "youtube.com" ? { "/watch": "v", "/results": "search_query" }[path]
    : h.startsWith("google.") && path === "/search" ? "q" : undefined;
  const query = () => {
    const name = queryName(host(), location.pathname.replace(/\/$/, ""));
    const value = name && new URLSearchParams(location.search).get(name);
    return value ? `?${name}=${encodeURIComponent(value)}` : "";
  };
  const page = () => ({
    url: host() + location.pathname + query(),
    host: host(),
    page: (location.pathname === "/" ? host() : host() + location.pathname.replace(/\/$/, "")) + query(),
    title: document.title,
  });
  let openOnReady = false;

  const frame = document.createElement("iframe");
  frame.src = chrome.runtime.getURL("overlay.html");
  frame.title = "NoteAnywhere";
  // The frosted glass lives here: a backdrop-filter inside the cross-origin frame can't see the page behind it.
  const frost = "blur(24px) saturate(180%)", shadow = "0 0 0 .5px rgba(0,0,0,.06), 0 2px 6px rgba(0,0,0,.08), 0 12px 32px rgba(0,0,0,.18)";
  frame.style.cssText = "all: initial; position: fixed; top: 8px; right: 8px; width: 340px; height: 0; border: 0;" +
    "z-index: 2147483647; display: none; color-scheme: normal; border-radius: 14px;" +
    `backdrop-filter: ${frost}; -webkit-backdrop-filter: ${frost}; box-shadow: ${shadow};`;
  let resizingFrame = false;
  document.documentElement.append(frame);

  // Where the panel sits: its gap from the top and right edges. Dragged by its header (overlay.js), remembered for all
  // pages, and kept on screen with the header reachable.
  let spot = { top: 8, right: 8 }, dragStart = null;
  const place = () => {
    spot = { top: Math.min(Math.max(spot.top, 0), Math.max(0, innerHeight - 60)),
      right: Math.min(Math.max(spot.right, 0), Math.max(0, innerWidth - (frame.offsetWidth || 340))) };
    frame.style.top = `${spot.top}px`;
    frame.style.right = `${spot.right}px`;
  };
  chrome.storage?.local.get("panelSpot").then(({ panelSpot }) => { if (panelSpot) { spot = panelSpot; place(); } }).catch(() => {});

  // Firefox doesn't pass a content script's messages to the panel's frame; the background forwards them (background.js).
  const viaBackground = chrome.runtime.getURL("").startsWith("moz-extension:");
  const tell = (type, extra) => chrome.runtime.sendMessage(viaBackground ? { type: "mn:panel", message: { type, ...extra } }
    : { type, ...extra }).catch(() => {});
  const calm = matchMedia("(prefers-reduced-motion: reduce)");
  frame.addEventListener("transitionend", () => { frame.style.transition = "none"; });

  chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
    if (msg.type === "toggle") {
      openOnReady = true; // the frame may still be loading when the icon/shortcut is used
      tell("mn:toggle");
    } else if (msg.type === "mn:ready") {
      sendResponse({ ...page(), open: openOnReady });
    } else if (msg.type === "mn:resizing") {
      // Resizing from the bottom-left grip: cover everything left of and below the panel's top-right corner, without
      // the frost (it would blur all of that); the panel's next report shrinks the frame back.
      resizingFrame = msg.on;
      Object.assign(frame.style, msg.on
        ? { width: `${innerWidth - spot.right}px`, height: `${innerHeight - spot.top}px`, backdropFilter: "none",
          webkitBackdropFilter: "none", boxShadow: "none", transition: "none" }
        : { backdropFilter: frost, webkitBackdropFilter: frost, boxShadow: shadow });
      sendResponse(true);
    } else if (msg.type === "mn:frame") {
      if (resizingFrame) return sendResponse(innerHeight - spot.top + 8);
      const width = `${msg.width || 340}px`;
      // Animate only the expand/shrink; content-driven height changes (typing) must follow at once.
      if (frame.style.width !== width && frame.style.display !== "none" && msg.visible && !calm.matches && msg.animate !== false) {
        frame.style.transition = "width .25s ease, height .25s ease";
      }
      frame.style.display = msg.visible ? "block" : "none";
      frame.style.width = width;
      frame.style.height = `${Math.min(msg.height, innerHeight - spot.top - 8)}px`;
      // The frame can't see the page's viewport; it caps the panel and note heights with this (the room below its top).
      sendResponse(innerHeight - spot.top + 8);
    } else if (msg.type === "mn:drag") { // dx/dy: how far the pointer has moved since the drag began
      if (msg.phase === "start") dragStart = { ...spot };
      if (!dragStart) return;
      spot = { top: dragStart.top + msg.dy, right: dragStart.right - msg.dx };
      place();
      if (msg.phase === "end") {
        dragStart = null;
        chrome.storage?.local.set({ panelSpot: spot }).catch(() => {});
      }
    }
  });

  addEventListener("resize", () => { place(); if (frame.style.display !== "none") tell("mn:resize"); });
  document.addEventListener("visibilitychange", () => { if (!document.hidden) tell("mn:context", { nav: false, page: page() }); });

  // shortcut: polling for SPA navigation, upgrade to the Navigation API if CPU matters.
  let lastUrl = page().url;
  setInterval(() => {
    if (page().url === lastUrl) return;
    lastUrl = page().url;
    tell("mn:context", { nav: true, page: page() });
  }, 1000);
})();
