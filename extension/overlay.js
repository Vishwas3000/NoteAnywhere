// The overlay UI. It runs in an extension frame, so the page never sees its keystrokes, focus or styles.
// Page context comes from content.js via extension messaging (the page can't forge it, unlike postMessage).
const HOST = "com.memorynotes.host";
const MISSING = "Mac app not installed — run scripts/install.sh";

let tabId, page = {};
let notes = [], visible = false, dismissed = false, collapsed = false, forced = false, error = "";
let query = "", results = [], searchSeq = 0, searchTimer;

const $ = (s) => document.querySelector(s);
const [panel, count, body, list, empty, errBox] = [".panel", ".count", ".body", ".notes", ".empty", ".error"].map($);
const [searchBox, resultList, noResults, footer] = [".search", ".results", ".no-results", "footer"].map($);

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
  const shown = query ? resultList : list;
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
$(".add-site").onclick = () => add(page.host, page.host);
$(".add-page").onclick = () => add(page.page, page.title || page.page);

function render() {
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
  report();
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
  // confirm() is blocked in cross-origin frames, so a note with text needs a second click.
  let armed;
  del.onclick = () => {
    if (!note.text.trim() || armed) return remove(note);
    del.textContent = "Really delete?";
    armed = setTimeout(() => { armed = undefined; del.textContent = "Delete"; }, 3000);
  };
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
  error = r.ok ? "" : r.error;
  errBox.textContent = error;
  errBox.hidden = !error;
}

async function add(target, label) {
  const now = Date.now();
  const note = { id: crypto.randomUUID(), kind: "url", target, label, text: "", createdAt: now, updatedAt: now };
  const r = await send({ op: "save", note });
  if (!r.ok) { error = r.error; return render(); }
  error = "";
  notes.push(r.note);
  collapsed = false;
  render();
  list.lastElementChild?.querySelector("textarea").focus();
}

async function remove(note) {
  const r = await send({ op: "delete", id: note.id });
  if (!r.ok) { error = r.error; return render(); }
  notes = notes.filter((n) => n !== note);
  render();
}

// nav: a new page, so auto-show/hide afresh. Otherwise a refresh: never clobber an in-progress edit.
async function load(nav) {
  if (!nav && document.activeElement?.tagName === "TEXTAREA") return;
  const r = await send({ op: "list", url: page.url });
  error = r.ok ? "" : r.error;
  if (r.ok) notes = r.notes;
  else if (nav) notes = [];
  // forced: opened by toggle on this page, so a slower first load mustn't hide it again.
  if (nav) { dismissed = false; visible = forced || notes.length > 0; }
  else if (notes.length && !dismissed) visible = true;
  render();
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
