// The overlay UI. It runs in an extension frame, so the page never sees its keystrokes, focus or styles.
// Page context comes from content.js via extension messaging (the page can't forge it, unlike postMessage).
const HOST = "com.memorynotes.host";
const MISSING = "Mac app not installed — run scripts/install.sh";

let tabId, page = {};
let notes = [], visible = false, dismissed = false, collapsed = false, forced = false, error = "";
let query = "", results = [], searchSeq = 0, searchTimer;
let editors = [], toolbarOn = false;

const $ = (s) => document.querySelector(s);
const [panel, count, body, list, empty, errBox] = [".panel", ".count", ".body", ".notes", ".empty", ".error"].map($);
const [searchBox, resultList, noResults, footer, help] = [".search", ".results", ".no-results", "footer", ".help"].map($);

function send(msg) {
  return new Promise((resolve) => {
    chrome.runtime.sendNativeMessage(HOST, msg, (reply) => {
      if (chrome.runtime.lastError) resolve({ ok: false, error: MISSING });
      else resolve(reply ?? { ok: false, error: "Empty reply from the Mac app" });
    });
  });
}

// Tell content.js whether to show the frame and how tall the panel wants to be.
function report() {
  if (tabId === undefined) return; // not wired up yet; the first load reports
  const shown = query ? resultList : help.hidden ? list : help;
  const height = panel.offsetHeight - shown.clientHeight + shown.scrollHeight + 16;
  chrome.tabs.sendMessage(tabId, { type: "mn:frame", visible, height }, { frameId: 0 }).catch(() => {});
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
  count.textContent = ` ${notes.length}`;
  body.hidden = collapsed;
  $(".collapse").textContent = collapsed ? "+" : "−";
  $(".collapse").setAttribute("aria-label", collapsed ? "Expand" : "Collapse");
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
  list.replaceChildren(...notes.map(noteRow));
  render();
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
    row.onclick = () => { row.setAttribute("aria-expanded", String(snippet.classList.toggle("full"))); report(); };
  } else {
    row.setAttribute("aria-label", `Open ${note.target}: ${note.text.split("\n")[0]}`);
    row.onclick = () => window.open(`https://${note.target}`, "_blank", "noopener");
  }
  return row;
}

// Notes for this page have no location label; notes for pages under it link there ("↳ /vercel/next.js").
function whereLabel(note) {
  if (note.target === page.page) return null;
  const a = document.createElement("a");
  a.href = `https://${note.target}`;
  a.target = "_blank";
  a.rel = "noopener";
  a.textContent = note.target.startsWith(page.page + "/") ? `↳ ${note.target.slice(page.page.length)}` : note.target;
  a.title = note.label || note.target;
  return a;
}

function noteRow(note) {
  const row = document.createElement("div");
  const meta = document.createElement("div");
  meta.className = "meta";
  const where = document.createElement("span");
  const link = whereLabel(note);
  if (link) where.append(link);
  const del = document.createElement("button");
  del.textContent = "Delete";
  del.setAttribute("aria-label", `Delete note${link ? ` for ${note.target}` : ""}`);
  // confirm() is blocked in cross-origin frames, so a note with text needs a second click.
  let armed;
  del.onclick = () => {
    if (!note.text.trim() || armed) return remove(note);
    del.textContent = "Really delete?";
    armed = setTimeout(() => { armed = undefined; del.textContent = "Delete"; }, 3000);
  };
  meta.append(where, del);

  const box = document.createElement("div");
  box.className = "note-editor";
  let timer;
  editors.push(MNEditor.mount(box, {
    markdown: note.text,
    placeholder: "Write a note…",
    toolbar: toolbarOn,
    onChange: (md) => {
      note.text = md;
      note.updatedAt = Date.now();
      clearTimeout(timer);
      timer = setTimeout(() => save(note), 400);
    },
  }));
  row.append(meta, box);
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
  if (!nav && editors.some((ed) => ed.isFocused())) return;
  const r = await send({ op: "list", url: page.url });
  error = r.ok ? "" : r.error;
  const before = JSON.stringify(notes);
  if (r.ok) notes = r.notes;
  else if (nav) notes = [];
  // forced: opened by toggle on this page, so a slower first load mustn't hide it again.
  if (nav) { dismissed = false; visible = forced || notes.length > 0; }
  else if (notes.length && !dismissed) visible = true;
  // Rebuilding unchanged editors would drop the cursor (and focus) the user just placed.
  JSON.stringify(notes) === before ? render() : renderNotes();
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
    load(msg.nav);
  }
});

(async () => {
  tabId = await chrome.runtime.sendMessage({ type: "mn:whoami" });
  page = await chrome.tabs.sendMessage(tabId, { type: "mn:ready" }, { frameId: 0 });
  forced = page.open;
  load(true);
})();
