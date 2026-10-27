if (window.top === window) (() => {
  const MISSING = "Mac app not installed — run scripts/install.sh";
  const host = () => location.host.replace(/^www\./, "");
  const currentUrl = () => host() + location.pathname;
  const pageTarget = () => (location.pathname === "/" ? host() : host() + location.pathname.replace(/\/$/, ""));

  let notes = [], visible = false, dismissed = false, collapsed = false, forced = false, error = "";
  let query = "", results = [], searchSeq = 0, searchTimer;

  async function send(msg) {
    try {
      return await chrome.runtime.sendMessage(msg);
    } catch (e) {
      return { ok: false, error: String(e.message || e) }; // e.g. extension reloaded under this tab
    }
  }
  const errorText = (r) => (r.error === "host-missing" ? MISSING : r.error || "Unknown error");

  // UI: static markup only; note data goes in via textContent/value.
  const el = document.createElement("memorynotes-overlay");
  const root = el.attachShadow({ mode: "closed" });
  root.innerHTML = `
    <style>
      :host { all: initial; position: fixed; top: 16px; right: 16px; z-index: 2147483647; }
      .panel { --bg:#fffef8; --fg:#1d1d1f; --mute:#6e6e73; --line:#e5e3d8; --field:#fff; --accent:#c48a00;
        width: 320px; max-height: 70vh; display: flex; flex-direction: column; background: var(--bg); color: var(--fg);
        border: 1px solid var(--line); border-radius: 12px; box-shadow: 0 8px 28px rgba(0,0,0,.18);
        font: 13px/1.4 system-ui, -apple-system, sans-serif; overflow: hidden; }
      @media (prefers-color-scheme: dark) {
        .panel { --bg:#26251f; --fg:#f2f1ea; --mute:#a19f94; --line:#3a3930; --field:#1c1b17; --accent:#f0b429; }
      }
      header { display: flex; align-items: center; gap: 6px; padding: 8px 10px; border-bottom: 1px solid var(--line); }
      header strong { flex: 1; font-size: 13px; }
      .count { color: var(--mute); font-weight: normal; margin-left: 4px; }
      button { font: inherit; color: inherit; background: none; border: 1px solid transparent; border-radius: 6px; cursor: pointer; padding: 2px 8px; }
      button:hover, button:focus-visible { border-color: var(--line); outline: none; }
      .body { display: flex; flex-direction: column; min-height: 0; }
      .list { overflow-y: auto; padding: 8px 10px; display: flex; flex-direction: column; gap: 10px; }
      .meta { display: flex; align-items: center; gap: 6px; color: var(--mute); font-size: 11px; margin-bottom: 3px; }
      .meta span { flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      textarea { box-sizing: border-box; width: 100%; min-height: 64px; resize: vertical; font: inherit; color: var(--fg);
        background: var(--field); border: 1px solid var(--line); border-radius: 8px; padding: 6px 8px; }
      textarea:focus { outline: 2px solid var(--accent); outline-offset: -1px; }
      .empty, .error { padding: 8px 10px; color: var(--mute); }
      .error { color: #d14; }
      footer { display: flex; gap: 6px; padding: 8px 10px; border-top: 1px solid var(--line); }
      footer button { flex: 1; border-color: var(--line); }
      .search { box-sizing: border-box; width: calc(100% - 20px); margin: 8px 10px 0; font: inherit; color: var(--fg);
        background: var(--field); border: 1px solid var(--line); border-radius: 8px; padding: 5px 8px; }
      .search:focus { outline: 2px solid var(--accent); outline-offset: -1px; }
      .results button { display: block; width: 100%; text-align: left; border-color: var(--line); padding: 6px 8px; }
      .results .meta { margin-bottom: 2px; }
      .snippet { display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; white-space: pre-wrap; }
      .snippet.full { display: block; -webkit-line-clamp: unset; user-select: text; }
      [hidden] { display: none !important; }
    </style>
    <div class="panel" role="complementary" aria-label="MemoryNotes">
      <header>
        <strong>Notes<span class="count"></span></strong>
        <button class="collapse" aria-label="Collapse">−</button>
        <button class="close" aria-label="Close">×</button>
      </header>
      <div class="body">
        <input class="search" type="search" placeholder="Search all notes…" aria-label="Search all notes">
        <div class="error" role="alert" hidden></div>
        <div class="list"></div>
        <div class="list results" hidden></div>
        <div class="empty">No notes here yet.</div>
        <div class="empty no-results" hidden>No matching notes</div>
        <footer>
          <button class="add-site">+ This site</button>
          <button class="add-page">+ This page</button>
        </footer>
      </div>
    </div>`;
  const $ = (s) => root.querySelector(s);
  const [count, body, list, empty, errBox] = [".count", ".body", ".list", ".empty", ".error"].map($);
  const [searchBox, resultList, noResults, footer] = [".search", ".results", ".no-results", "footer"].map($);

  // Keep typing in the overlay from triggering the page's own keyboard shortcuts (GitHub, YouTube, …).
  for (const type of ["keydown", "keyup", "keypress"]) root.addEventListener(type, (e) => e.stopPropagation());

  searchBox.oninput = () => {
    clearTimeout(searchTimer);
    query = searchBox.value.trim();
    if (!query) { searchSeq++; results = []; return render(); }
    searchTimer = setTimeout(search, 300);
  };
  searchBox.onkeydown = (e) => {
    if (e.key !== "Escape") return;
    searchBox.value = "";
    searchBox.oninput();
  };

  $(".collapse").onclick = () => { collapsed = !collapsed; render(); };
  $(".close").onclick = () => { visible = false; dismissed = true; render(); };
  $(".add-site").onclick = () => add(host(), host());
  $(".add-page").onclick = () => add(pageTarget(), document.title || pageTarget());

  function render() {
    el.style.display = visible ? "" : "none";
    count.textContent = ` ${notes.length}`;
    body.hidden = collapsed;
    $(".collapse").textContent = collapsed ? "+" : "−";
    $(".collapse").setAttribute("aria-label", collapsed ? "Expand" : "Collapse");
    errBox.textContent = error;
    errBox.hidden = !error;
    const searching = query !== "";
    list.hidden = searching;
    footer.hidden = searching;
    empty.hidden = searching || notes.length > 0;
    resultList.hidden = !searching;
    noResults.hidden = !searching || results.length > 0;
    if (searching) resultList.replaceChildren(...results.map(resultRow));
    else list.replaceChildren(...notes.map(noteRow));
  }

  async function search() {
    const seq = ++searchSeq;
    const r = await send({ op: "search", query });
    if (seq !== searchSeq) return; // a newer query (or a cleared box) superseded this one
    error = r.ok ? "" : errorText(r);
    results = r.ok ? r.results.map((x) => x.note) : [];
    render();
  }

  function resultRow(note) {
    const row = document.createElement("button");
    const meta = document.createElement("div");
    meta.className = "meta";
    meta.textContent = note.kind === "app" ? `App · ${note.label || note.target}` : `Site · ${note.target}`;
    const snippet = document.createElement("div");
    snippet.className = "snippet";
    snippet.textContent = note.text || "Empty note";
    row.append(meta, snippet);
    if (note.kind === "app") {
      row.setAttribute("aria-expanded", "false");
      row.onclick = () => row.setAttribute("aria-expanded", String(snippet.classList.toggle("full")));
    } else {
      row.setAttribute("aria-label", `Open ${note.target}: ${note.text.split("\n")[0]}`);
      row.onclick = () => window.open(`https://${note.target}`, "_blank", "noopener");
    }
    return row;
  }

  function noteRow(note) {
    const row = document.createElement("div");
    const meta = document.createElement("div");
    meta.className = "meta";
    const label = document.createElement("span");
    label.textContent = (note.target.includes("/") ? "Page · " : "Site · ") + note.target;
    label.title = note.label || note.target;
    const del = document.createElement("button");
    del.textContent = "Delete";
    del.setAttribute("aria-label", `Delete note for ${note.target}`);
    del.onclick = () => remove(note);
    meta.append(label, del);

    const ta = document.createElement("textarea");
    ta.value = note.text;
    ta.setAttribute("aria-label", `Note for ${note.target}`);
    let timer;
    ta.oninput = () => {
      note.text = ta.value;
      note.updatedAt = Date.now();
      clearTimeout(timer);
      timer = setTimeout(() => save(note), 400);
    };
    row.append(meta, ta);
    return row;
  }

  async function save(note) {
    const r = await send({ op: "save", note });
    error = r.ok ? "" : errorText(r);
    errBox.textContent = error;
    errBox.hidden = !error;
  }

  async function add(target, label) {
    const now = Date.now();
    // id is filled in by background.js: crypto.randomUUID() is missing on http:// pages.
    const r = await send({ op: "save", note: { kind: "url", target, label, text: "", createdAt: now, updatedAt: now } });
    if (!r.ok) { error = errorText(r); return render(); }
    error = "";
    notes.push(r.note);
    collapsed = false;
    render();
    list.lastElementChild?.querySelector("textarea").focus();
  }

  async function remove(note) {
    if (note.text.trim() && !confirm("Delete this note?")) return;
    const r = await send({ op: "delete", id: note.id });
    if (!r.ok) { error = errorText(r); return render(); }
    notes = notes.filter((n) => n !== note);
    render();
  }

  // nav: a new page, so auto-show/hide afresh. Otherwise a refresh: never clobber an in-progress edit.
  async function load(nav) {
    if (!nav && root.activeElement?.tagName === "TEXTAREA") return;
    const r = await send({ op: "list", url: currentUrl() });
    error = r.ok ? "" : errorText(r);
    if (r.ok) notes = r.notes;
    else if (nav) notes = [];
    // forced: opened by toggle on this page, so a slower first load mustn't hide it again.
    if (nav) { dismissed = false; visible = forced || notes.length > 0; }
    else if (notes.length && !dismissed) visible = true;
    render();
  }

  chrome.runtime.onMessage.addListener((msg) => {
    if (msg.type !== "toggle") return;
    visible = !visible;
    forced = visible;
    dismissed = !visible;
    render();
  });

  document.addEventListener("visibilitychange", () => { if (!document.hidden) load(false); });

  // shortcut: polling for SPA navigation, upgrade to the Navigation API if CPU matters.
  let lastUrl = currentUrl();
  setInterval(() => {
    if (currentUrl() !== lastUrl) { lastUrl = currentUrl(); forced = false; load(true); }
  }, 1000);

  document.documentElement.append(el);
  render();
  load(true);
})();
