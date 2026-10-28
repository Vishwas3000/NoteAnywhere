// The overlay UI. It runs in an extension frame, so the page never sees its keystrokes, focus or styles.
// Page context comes from content.js via extension messaging (the page can't forge it, unlike postMessage).
const HOST = "com.memorynotes.host";
const MISSING = "Mac app not installed — run scripts/install.sh";

let tabId, page = {};
let notes = [], visible = false, dismissed = false, collapsed = false, forced = false, error = "";
let query = "", results = [], searchSeq = 0, searchTimer;
let editors = [], stamps = [], toolbarOn = false, expanded = false, hostH;

const $ = (s) => document.querySelector(s);
const [panel, count, body, list, empty, errBox] = [".panel", ".count", ".body", ".notes", ".empty", ".error"].map($);
const [searchBox, resultList, noResults, footer, help] = [".search", ".results", ".no-results", "footer", ".help"].map($);
const [favicon, hostName, pageTitle] = [".site img", ".host", ".page-title"].map($);
const store = chrome.storage?.local; // needs the "storage" permission; without it the size choice just isn't remembered

function send(msg) {
  return new Promise((resolve) => {
    chrome.runtime.sendNativeMessage(HOST, msg, (reply) => {
      if (chrome.runtime.lastError) resolve({ ok: false, error: MISSING });
      else resolve(reply ?? { ok: false, error: "Empty reply from the Mac app" });
    });
  });
}

// Mirrors Note.plain in Sources/MemoryNotes/Note.swift: one Markdown line as plain text.
const plain = (line) => line
  .replace(/^\s*(#{1,6}\s+|>\s*|[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|\d+[.)]\s+)*/, "")
  .replace(/^\s*(-{3,}|\*{3,}|_{3,}|\|?[\s:|-]+\|[\s:|-]*)\s*$/, "")
  .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
  .replace(/\*\*|__|~~|`/g, "")
  .replace(/\*(\S|\S[^*]*\S)\*/g, "$1")
  .replace(/\s*\|\s*/g, "  ")
  .trim();
function plainLines(text) {
  let fence = false;
  return text.split("\n").flatMap((line) => {
    if (line.startsWith("```")) { fence = !fence; return []; }
    const p = fence ? line.trim() : plain(line);
    return p ? [p] : [];
  });
}

function edited(ms) {
  const d = new Date(ms), mins = (Date.now() - ms) / 60e3;
  if (mins < 1) return "Edited just now";
  if (mins < 60) return `Edited ${Math.floor(mins)} min ago`;
  if (d.toDateString() === new Date().toDateString()) return `Edited ${d.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}`;
  if (d.toDateString() === new Date(Date.now() - 864e5).toDateString()) return "Edited yesterday";
  const year = d.getFullYear() === new Date().getFullYear() ? undefined : "numeric";
  return `Edited ${d.toLocaleDateString([], { month: "short", day: "numeric", year })}`;
}

// Tell content.js whether to show the frame and how big the panel wants to be. It replies with the page's viewport height.
function report() {
  if (tabId === undefined) return; // not wired up yet; the first load reports
  const shown = query ? resultList : help.hidden ? list : help;
  const height = expanded && !collapsed && hostH ? hostH : panel.offsetHeight - shown.clientHeight + shown.scrollHeight;
  chrome.tabs.sendMessage(tabId, { type: "mn:frame", visible, height, width: panel.offsetWidth }, { frameId: 0 })
    .then((h) => {
      if (!h || h === hostH) return;
      hostH = h;
      document.documentElement.style.setProperty("--host-h", `${h}px`);
      report();
    })
    .catch(() => {});
}
new ResizeObserver(report).observe(panel);

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
$(".add").onclick = () => add();
$(".format").onclick = () => {
  toolbarOn = !toolbarOn;
  $(".format").setAttribute("aria-pressed", String(toolbarOn));
  for (const ed of editors) ed.setToolbar(toolbarOn);
};
$(".help-toggle").onclick = () => {
  help.hidden = !help.hidden;
  $(".help-toggle").setAttribute("aria-expanded", String(!help.hidden));
  render();
};
$(".expand").onclick = () => {
  expanded = !expanded;
  store?.set({ expanded });
  render();
};
favicon.onload = () => { favicon.hidden = false; }; // until then (or if the site has none) a globe shows

// The shortcut list comes from the editor bundle, so it can't drift from what the editor does.
let lastGroup;
for (const { group, keys, action } of MNEditor.shortcuts) {
  if (group !== lastGroup) {
    const h = document.createElement("h3");
    h.textContent = lastGroup = group;
    help.append(h);
  }
  const row = document.createElement("div");
  const k = document.createElement("kbd");
  k.textContent = keys;
  const a = document.createElement("span");
  a.textContent = action;
  row.append(k, a);
  help.append(row);
}

// State only. The note editors are rebuilt by renderNotes(), and only when the note set changes,
// so typing, searching or collapsing never resets the cursor.
function render() {
  count.textContent = notes.length ? `${notes.length}` : "";
  count.title = `${notes.length} note${notes.length === 1 ? "" : "s"} on this page`;
  body.hidden = collapsed;
  $(".collapse").setAttribute("aria-expanded", String(!collapsed));
  $(".collapse").setAttribute("aria-label", collapsed ? "Show notes" : "Collapse notes");
  $(".collapse").title = collapsed ? "Show notes" : "Collapse";
  panel.classList.toggle("expanded", expanded);
  $(".expand").setAttribute("aria-pressed", String(expanded));
  $(".expand").setAttribute("aria-label", expanded ? "Shrink panel" : "Expand panel");
  $(".expand").title = expanded ? "Shrink panel" : "Expand panel";
  errBox.textContent = error;
  errBox.hidden = !error;
  const searching = query !== "";
  list.hidden = searching || !help.hidden;
  footer.hidden = searching || !help.hidden;
  empty.hidden = searching || !help.hidden || notes.length > 0;
  resultList.hidden = !searching;
  noResults.hidden = !searching || results.length > 0;
  if (searching) resultList.replaceChildren(...results.map(resultRow));
  report();
}

function renderNotes() {
  for (const ed of editors) ed.destroy();
  editors = [];
  stamps = [];
  list.replaceChildren(...notes.map(noteRow));
  render();
}

function showPage() {
  hostName.textContent = page.host || "Notes";
  pageTitle.textContent = page.title || page.page || "";
  pageTitle.title = page.title || "";
  const src = page.host ? `https://${page.host}/favicon.ico` : "";
  if (favicon.getAttribute("src") !== src) { favicon.hidden = true; favicon.src = src; }
}

async function search() {
  const seq = ++searchSeq;
  const r = await send({ op: "search", query });
  if (seq !== searchSeq) return; // a newer query (or a cleared box) superseded this one
  error = r.ok ? "" : r.error;
  results = r.ok ? r.results.map((x) => x.note) : [];
  render();
}

function resultRow(note) {
  const [title = "New Note", ...rest] = plainLines(note.text);
  const row = document.createElement("button");
  row.className = "card";
  const head = document.createElement("div");
  head.className = "r-title";
  head.textContent = title;
  const snippet = document.createElement("div");
  snippet.className = "snippet";
  snippet.textContent = rest.slice(0, 4).join(" ");
  const meta = document.createElement("div");
  meta.className = "meta";
  meta.textContent = note.kind === "app" ? `App · ${note.label || note.target}` : `Site · ${note.target}`;
  row.append(head, snippet, meta);
  if (note.kind === "app") {
    row.setAttribute("aria-expanded", "false");
    row.onclick = () => {
      const full = snippet.classList.toggle("full");
      snippet.textContent = full ? rest.join("\n") : rest.slice(0, 4).join(" ");
      row.setAttribute("aria-expanded", String(full));
      report();
    };
  } else {
    row.setAttribute("aria-label", `Open ${note.target}: ${title}`);
    row.onclick = () => window.open(`https://${note.target}`, "_blank", "noopener");
  }
  return row;
}

// Notes for this page have no location label; notes for pages under it link there ("↳ /vercel/next.js").
function whereLabel(note) {
  if (note.target === page.page) return null;
  const a = document.createElement("a");
  a.className = "where-link";
  a.href = `https://${note.target}`;
  a.target = "_blank";
  a.rel = "noopener";
  a.textContent = note.target.startsWith(page.page + "/") ? `↳ ${note.target.slice(page.page.length)}` : note.target;
  a.title = note.label || note.target;
  return a;
}

const TRASH = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M3 6h18M8 6V4h8v2M19 6l-1 14H6L5 6M10 11v5M14 11v5"/></svg>';

function noteRow(note) {
  const row = document.createElement("article");
  row.className = "card";
  const link = whereLabel(note);
  if (link) row.append(link);

  const box = document.createElement("div");
  box.className = "editor";
  const meta = document.createElement("div");
  meta.className = "meta";
  const stamp = document.createElement("span");
  stamp.textContent = edited(note.updatedAt);
  const del = document.createElement("button");
  del.className = "icon del";
  del.innerHTML = TRASH; // our own constant markup
  del.title = "Delete";
  del.setAttribute("aria-label", `Delete note${link ? ` for ${note.target}` : ""}`);
  // confirm() is blocked in cross-origin frames, so a note with text needs a second click.
  let armed;
  del.onclick = () => {
    if (!note.text.trim() || armed) return remove(note);
    del.textContent = "Delete?";
    del.classList.add("armed");
    armed = setTimeout(() => { armed = undefined; del.innerHTML = TRASH; del.classList.remove("armed"); }, 3000);
  };
  meta.append(stamp, del);

  let timer;
  editors.push(MNEditor.mount(box, {
    markdown: note.text,
    placeholder: "Write a note…",
    toolbar: toolbarOn,
    // Apple Notes' first-line title, unless that line is a long paragraph that would become a wall of bold text.
    titleLine: (plainLines(note.text)[0] ?? "").length <= 60,
    onChange: (md) => {
      note.text = md;
      note.updatedAt = Date.now();
      stamp.textContent = edited(note.updatedAt);
      clearTimeout(timer);
      timer = setTimeout(() => save(note), 400);
    },
  }));
  stamps.push(stamp);
  row.append(box, meta);
  return row;
}

async function save(note) {
  const r = await send({ op: "save", note });
  error = r.ok ? "" : r.error;
  errBox.textContent = error;
  errBox.hidden = !error;
}

async function add() {
  const now = Date.now();
  const note = { id: crypto.randomUUID(), kind: "url", target: page.page, label: page.title || page.page, text: "", createdAt: now, updatedAt: now };
  const r = await send({ op: "save", note });
  if (!r.ok) { error = r.error; return render(); }
  error = "";
  notes.push(r.note);
  collapsed = false;
  renderNotes();
  editors.at(-1)?.focus();
}

async function remove(note) {
  const r = await send({ op: "delete", id: note.id });
  if (!r.ok) { error = r.error; return render(); }
  notes = notes.filter((n) => n !== note);
  renderNotes();
}

// nav: a new page, so auto-show/hide afresh. Otherwise a refresh: never clobber an in-progress edit.
async function load(nav) {
  const typing = () => !nav && editors.some((ed) => ed.isFocused());
  if (typing()) return;
  const r = await send({ op: "list", url: page.url });
  if (typing()) return; // focus may have moved into an editor while the Mac app answered
  error = r.ok ? "" : r.error;
  const fresh = r.ok ? r.notes : nav ? [] : notes;
  // forced: opened by toggle on this page, so a slower first load mustn't hide it again.
  if (nav) { dismissed = false; visible = forced || fresh.length > 0; }
  else if (fresh.length && !dismissed) visible = true;
  // Same notes: update changed ones in place, so cursors, scroll and the other cards stay put.
  if (!nav && fresh.length === notes.length && fresh.every((n, i) => n.id === notes[i].id)) {
    fresh.forEach((n, i) => {
      if (n.text !== notes[i].text) editors[i].setMarkdown(n.text);
      if (n.updatedAt !== notes[i].updatedAt) stamps[i].textContent = edited(n.updatedAt);
      Object.assign(notes[i], n); // the row's handlers hold this object
    });
    render();
  } else {
    notes = fresh;
    renderNotes();
  }
}

chrome.runtime.onMessage.addListener((msg, sender) => {
  if (sender.tab?.id !== tabId) return; // content scripts in other tabs broadcast too
  if (msg.type === "mn:toggle") {
    visible = !visible;
    forced = visible;
    dismissed = !visible;
    render();
  } else if (msg.type === "mn:context") {
    if (msg.nav) forced = false;
    page = msg.page;
    showPage();
    load(msg.nav);
  } else if (msg.type === "mn:resize") {
    report();
  }
});

(async () => {
  tabId = await chrome.runtime.sendMessage({ type: "mn:whoami" });
  page = await chrome.tabs.sendMessage(tabId, { type: "mn:ready" }, { frameId: 0 });
  forced = page.open;
  expanded = !!(await store?.get("expanded").catch(() => null))?.expanded;
  showPage();
  load(true);
})();
