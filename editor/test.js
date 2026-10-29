// Runs the built bundle in happy-dom and checks Markdown round-trips and list keyboard behavior.
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import { Window } from "happy-dom";

// Only our own build is evaluated; `npm test` runs node with --disallow-code-generation-from-strings, which also
// proves the bundle needs no eval (CSP-safe for the extension and the app's WebView).
const window = new Window({ settings: { enableJavaScriptEvaluation: true, suppressInsecureJavaScriptEnvironmentWarning: true } });
// happy-dom has no compatMode; the real pages declare <!doctype html> (standards mode), which KaTeX requires.
Object.defineProperty(window.document, "compatMode", { value: "CSS1Compat" });
window.eval(readFileSync("dist/mn-editor.js", "utf8"));
const { MNEditor, document } = window;
assert.ok(MNEditor?.mount, "bundle exposes window.MNEditor.mount");

let failed = 0;
function check(name, fn) {
  try { fn(); console.log("ok  ", name); } catch (e) { failed++; console.log("FAIL", name, "\n    ", e.message.split("\n").join("\n     ")); }
}
function mount(markdown, extra = {}) {
  const el = document.createElement("div");
  document.body.append(el);
  return MNEditor.mount(el, { markdown, ...extra });
}
const roundTrip = (md) => assert.equal(mount(md).getMarkdown().trim(), md);
// Put the cursor at the end of the first text node containing `text`, then press `key` like a user would.
function press(ed, text, key, shift = false) {
  const { state } = ed.editor;
  let at = -1;
  state.doc.descendants((node, pos) => { if (at < 0 && node.isText && node.text.includes(text)) at = pos + node.text.indexOf(text) + text.length; });
  assert.ok(at >= 0, `found "${text}"`);
  ed.editor.commands.setTextSelection(at);
  ed.editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", { key, shiftKey: shift, bubbles: true, cancelable: true }));
}

check("nested bullet list", () => roundTrip("- a\n  - b\n- c"));
check("task list", () => roundTrip("- [ ] todo\n- [x] done"));
// Tables come back column-padded; the padded form must then be stable.
check("table", () => roundTrip("| A   | B   |\n| --- | --- |\n| 1   | 2   |"));
check("links (web + note)", () => roundTrip("[site](https://example.com) and [other](note://ABCD-1234)"));
check("code block", () => roundTrip("```js\nconst x = 1;\n```"));
check("headings, quote, inline marks", () => roundTrip("# Title\n\n> quoted **bold** *it* ~~gone~~ `code`"));

check("Tab nests an item and the outer numbering stays in order", () => {
  const ed = mount("1. a\n2. b\n3. c");
  press(ed, "b", "Tab");
  assert.match(ed.getMarkdown(), /^1\. a\n\s+1\. b\n2\. c/);
});
check("Shift-Tab outdents it again", () => {
  const ed = mount("1. a\n   1. b\n2. c");
  press(ed, "b", "Tab", true);
  assert.equal(ed.getMarkdown().trim(), "1. a\n2. b\n3. c");
});
check("Enter continues a numbered list with the next number", () => {
  const ed = mount("1. a\n2. b");
  press(ed, "b", "Enter");
  ed.editor.commands.insertContent("c");
  assert.equal(ed.getMarkdown().trim(), "1. a\n2. b\n3. c");
});
check("Enter on an empty item ends the list", () => {
  const ed = mount("- a");
  press(ed, "a", "Enter");
  ed.editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  ed.editor.commands.insertContent("after");
  assert.equal(ed.getMarkdown().trim(), "- a\n\nafter");
});
check("Enter continues a checklist with an unchecked item", () => {
  const ed = mount("- [x] a");
  press(ed, "a", "Enter");
  ed.editor.commands.insertContent("b");
  assert.equal(ed.getMarkdown().trim(), "- [x] a\n- [ ] b");
});
check("onChange fires for edits but not for setMarkdown", () => {
  const seen = [];
  const ed = mount("x", { onChange: (md) => seen.push(md) });
  ed.setMarkdown("y");
  assert.equal(seen.length, 0);
  ed.editor.commands.insertContent("z");
  assert.equal(seen.length, 1);
});
check("note:// link click calls onLinkNote", () => {
  let got;
  const ed = mount("[other](note://ABCD-1234)", { onLinkNote: (id) => (got = id) });
  ed.editor.view.dom.querySelector("a").dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
  // ProseMirror routes clicks through mousedown/up; fall back to the prop directly if the synthetic click isn't routed.
  if (got === undefined) ed.editor.view.someProp("handleClick", (f) => f(ed.editor.view, 2, { target: ed.editor.view.dom.querySelector("a") }));
  assert.equal(got, "ABCD-1234");
});
check("Shift-Enter in a code block adds a line inside it", () => {
  const ed = mount("```\na\n```");
  press(ed, "a", "Enter", true);
  ed.editor.commands.insertContent("b");
  assert.equal(ed.getMarkdown().trim(), "```\na\nb\n```");
});
check("toolbar: false hides the toolbar", () => {
  const ed = mount("x", { toolbar: false });
  assert.equal(ed.editor.options.element.closest(".mn-editor").querySelector(".mn-toolbar").hidden, true);
});
check("#tags are highlighted, not in code, and ⌘-click reports them", () => {
  let got;
  const ed = mount("plan #ML and #project/notes, `#code`, #2024", { onTag: (t) => (got = t) });
  const tags = [...ed.editor.view.dom.querySelectorAll(".mn-tag")].map((t) => t.dataset.tag);
  assert.deepEqual(tags, ["ml", "project/notes"]);
  const el = ed.editor.view.dom.querySelector(".mn-tag");
  ed.editor.view.someProp("handleClick", (f) => f(ed.editor.view, 0, { metaKey: true, target: el }));
  assert.equal(got, "ml");
});
// ProseMirror's "Mod" is ⌘ only where the platform says Mac.
const mac = /Mac|iP(hone|[oa]d)/.test(window.navigator.platform);
const key = (ed, k) => ed.editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown",
  { key: k, metaKey: mac, ctrlKey: !mac, shiftKey: true, bubbles: true, cancelable: true }));
check("⌘⇧↓ / ⌘⇧↑ move a list item and keep the cursor in it", () => {
  const ed = mount("- a\n- b\n- c");
  ed.editor.commands.setTextSelection(3); // inside "a"
  key(ed, "ArrowDown");
  assert.equal(ed.getMarkdown().trim(), "- b\n- a\n- c");
  key(ed, "ArrowDown");
  assert.equal(ed.getMarkdown().trim(), "- b\n- c\n- a");
  key(ed, "ArrowDown"); // already last
  key(ed, "ArrowUp");
  assert.equal(ed.getMarkdown().trim(), "- b\n- a\n- c");
});
check("⌘⇧↑ moves a paragraph above a heading", () => {
  const ed = mount("# H\n\npara");
  ed.editor.commands.setTextSelection(ed.editor.state.doc.content.size - 2);
  key(ed, "ArrowUp");
  assert.equal(ed.getMarkdown().trim(), "para\n\n# H");
});
check("the drag handle is in the editor", () => {
  const ed = mount("x");
  ed.editor.commands.insertContent("y"); // any update attaches it
  assert.equal(ed.editor.view.dom.parentElement.querySelector(".mn-drag")?.draggable, true);
});
check("@tomorrow + space becomes a real date chip, and ⌘-click reports the day", () => {
  let got;
  const ed = mount("", { onDate: (d) => (got = d) });
  for (const ch of "Ship @tomorrow ") {
    const { from, to } = ed.editor.state.selection;
    if (!ed.editor.view.someProp("handleTextInput", (f) => f(ed.editor.view, from, to, ch))) ed.editor.commands.insertContent(ch);
  }
  const tomorrow = MNEditor.dayFor("tomorrow");
  assert.equal(ed.getMarkdown().trim(), `Ship @${tomorrow}`);
  const chip = ed.editor.view.dom.querySelector(".mn-date");
  assert.equal(chip?.dataset.day, tomorrow);
  ed.editor.view.someProp("handleClick", (f) => f(ed.editor.view, 0, { metaKey: true, target: chip }));
  assert.equal(got, tomorrow);
});
check("weekdays mean the next one, today included", () => {
  const wed = new Date(2026, 9, 28); // a Wednesday
  assert.equal(MNEditor.dayFor("wed", wed), "2026-10-28");
  assert.equal(MNEditor.dayFor("friday", wed), "2026-10-30");
  assert.equal(MNEditor.dayFor("mon", wed), "2026-11-02");
  assert.equal(MNEditor.dayFor("yesterday", wed), "2026-10-27");
});
check("Obsidian 📅 dates are chips too; impossible dates aren't", () => {
  const ed = mount("a 📅 2026-10-30 b @2026-02-30");
  assert.deepEqual([...ed.editor.view.dom.querySelectorAll(".mn-date")].map((c) => c.dataset.day), ["2026-10-30"]);
});
check("typing @ opens the date menu; Return picks Today, typing filters, Esc closes", () => {
  const ed = mount("Ship ");
  ed.editor.commands.focus("end");
  ed.editor.commands.insertContent("@");
  const menu = () => ed.editor.view.dom.parentElement.querySelector(".mn-at-menu");
  assert.ok(menu(), "menu shows after @");
  assert.equal(menu().querySelector(".mn-at-item").textContent.startsWith("Today"), true);
  ed.editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  assert.equal(ed.getMarkdown().trim(), `Ship @${MNEditor.dayFor("today")}`);
  assert.equal(menu(), null);
  ed.editor.commands.insertContent(" @tom");
  assert.deepEqual([...menu().querySelectorAll(".mn-at-item")].map((i) => i.firstChild.textContent), ["Tomorrow"]);
  ed.editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
  assert.equal(menu(), null);
  assert.match(ed.getMarkdown(), /@tom$/);
});
check("Pick a date… pops up a calendar; arrows and Return put that day in, Esc closes it", () => {
  const ed = mount("Call ");
  const key = (target, key) => target.dispatchEvent(new window.KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
  const cal = () => ed.editor.view.dom.parentElement.querySelector(".mn-cal");
  ed.editor.commands.focus("end");
  ed.editor.commands.insertContent("@pick");
  key(ed.editor.view.dom, "Enter");
  assert.ok(cal(), "calendar shows");
  assert.equal(cal().querySelector(".mn-cal-day.active").getAttribute("aria-current"), "date", "today is highlighted");
  const grid = cal().querySelector("[role=grid]");
  key(grid, "ArrowDown");
  key(grid, "ArrowRight");
  key(grid, "Enter");
  const now = new Date();
  assert.equal(ed.getMarkdown().trim(), `Call @${MNEditor.dayFor("today", new Date(now.getFullYear(), now.getMonth(), now.getDate() + 8))}`);
  assert.equal(cal(), null);
  ed.editor.options.element.closest(".mn-editor").querySelector('button[aria-label="Add a date"]').click();
  key(cal().querySelector("[role=grid]"), "PageDown");
  assert.equal(cal().querySelector(".mn-cal-title").textContent,
    new Date(now.getFullYear(), now.getMonth() + 1, 1).toLocaleDateString(undefined, { month: "long", year: "numeric" }));
  key(cal().querySelector("[role=grid]"), "Escape");
  assert.equal(cal(), null);
});
check("datePattern shows chips as 30/10/2026, keeps @2026-10-30, and shows the source while the caret is in it", () => {
  const ed = mount("Call @2026-10-30 and 📅 2026-11-02", { datePattern: "dd/MM/yyyy" });
  const chips = () => [...ed.editor.view.dom.querySelectorAll(".mn-date")].map((c) => c.textContent);
  assert.deepEqual(chips(), ["30/10/2026", "📅 02/11/2026"]);
  assert.equal(ed.getMarkdown().trim(), "Call @2026-10-30 and 📅 2026-11-02");
  ed.editor.commands.setTextSelection(9);  // inside "@2026-10-30"
  assert.deepEqual(chips(), ["@2026-10-30", "📅 02/11/2026"]);
  assert.equal(MNEditor.formatDay("2026-10-30", "MM/dd/yyyy"), "10/30/2026");
  assert.equal(MNEditor.formatDay("2026-10-30", "dd.MM.y"), "30.10.2026");
});
check("/ opens the block menu; typing filters it, Return applies the block and removes the /query", () => {
  const key = (k) => ed.editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true }));
  const menu = () => ed.editor.view.dom.parentElement.querySelector('.mn-at-menu[aria-label="Blocks"]');
  const labels = () => [...menu().querySelectorAll(".mn-at-item")].map((i) => i.firstChild.textContent);
  const ed = mount("Intro");
  ed.editor.commands.focus("end");
  ed.editor.commands.insertContent(" /");
  assert.ok(menu(), "menu shows after /");
  assert.equal(labels()[0], "Text");
  ed.editor.commands.insertContent("break page");
  assert.deepEqual(labels(), ["Break page"]);
  key("Enter");
  assert.equal(menu(), null);
  assert.equal(ed.getMarkdown().trim(), "Intro\n\n---");
  ed.editor.commands.focus("end");
  ed.editor.commands.insertContent("/todo");
  assert.deepEqual(labels(), ["To-do list"]);
  key("Enter");
  ed.editor.commands.insertContent("Buy milk");
  assert.match(ed.getMarkdown().trim(), /- \[ \] Buy milk$/);
  ed.editor.commands.insertContent(" see https://a.b/c");  // a slash inside a word or URL isn't a command
  assert.equal(menu(), null);
  ed.editor.commands.insertContent(" /zzz");
  assert.equal(menu(), null, "no match, no menu");
});
check("/divider and /h2 find their blocks", () => {
  const ed = mount("");
  ed.editor.commands.focus("end");
  ed.editor.commands.insertContent("/divider");
  const menu = ed.editor.view.dom.parentElement.querySelector('.mn-at-menu[aria-label="Blocks"]');
  assert.deepEqual([...menu.querySelectorAll(".mn-at-item")].map((i) => i.firstChild.textContent), ["Break page"]);
  ed.editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Escape", bubbles: true, cancelable: true }));
  ed.editor.commands.insertContent(" /h2");
  ed.editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  assert.match(ed.getMarkdown().trim(), /^## /);
});
const maths = (ed) => { const out = []; ed.editor.state.doc.descendants((n) => { if (n.type.name.endsWith("Math")) out.push(`${n.type.name}:${n.attrs.latex}`); }); return out; };
check("maths: \\(…\\), $…$, $$…$$ and \\[…\\] render and save as $…$ / $$…$$; prices stay text", () => {
  let ed = mount("Query (\\(Q = XW_Q\\)): what it looks for; costs $5 and $10");
  assert.deepEqual(maths(ed), ["inlineMath:Q = XW_Q"]);
  assert.equal(ed.getMarkdown().trim(), "Query ($Q = XW_Q$): what it looks for; costs $5 and $10");
  assert.ok(ed.editor.view.dom.querySelector('[data-type="inline-math"] math'), "drawn as MathML");
  ed = mount("\\[\n\\text{softmax}(x_i)\n\\]");
  assert.deepEqual(maths(ed), ["blockMath:\\text{softmax}(x_i)"]);
  assert.equal(ed.getMarkdown().trim(), "$$\n\\text{softmax}(x_i)\n$$");
  ed = mount("$$\n\\frac{QK^T}{\\sqrt{d_k}}\n$$");
  assert.equal(ed.getMarkdown().trim(), "$$\n\\frac{QK^T}{\\sqrt{d_k}}\n$$");
});
check("maths saved as text before (escaped) becomes a formula; typed maths renders once the caret leaves it", () => {
  const ed = mount("Key (\\\\(K = XW\\_K\\\\)) and more");
  assert.deepEqual(maths(ed), ["inlineMath:K = XW_K"]);
  ed.editor.commands.focus("end");
  ed.editor.commands.insertContent(" \\(V = XW_V\\)");
  assert.deepEqual(maths(ed), ["inlineMath:K = XW_K"], "not while the caret touches it");
  ed.editor.commands.insertContent(" done");
  assert.deepEqual(maths(ed), ["inlineMath:K = XW_K", "inlineMath:V = XW_V"]);
});
check("clicking a formula gives its source back to edit", () => {
  const ed = mount("Value $V = XW_V$ here");
  ed.editor.view.dom.querySelector('[data-type="inline-math"]').dispatchEvent(new window.MouseEvent("click", { bubbles: true, cancelable: true }));
  assert.deepEqual(maths(ed), []);
  assert.equal(ed.editor.state.doc.textContent, "Value $V = XW_V$ here");
  ed.editor.commands.setTextSelection(1);
  assert.deepEqual(maths(ed), ["inlineMath:V = XW_V"]);
});
check("shortcuts list is exported", () => assert.ok(MNEditor.shortcuts.length >= 20));

// ✨ menu: the host's reply replaces the whole note (or the selection) as one undoable step; titles go on top.
async function checkAsync(name, fn) {
  try { await fn(); console.log("ok  ", name); } catch (e) { failed++; console.log("FAIL", name, "\n    ", e.message); }
}
const ai = (ed, action) => [...ed.editor.options.element.closest(".mn-editor").querySelectorAll(".mn-ai-menu button")]
  .find((b) => b.textContent === Object.fromEntries(MNEditor.AI_ACTIONS)[action]).click();
const settle = () => new Promise((r) => setTimeout(r, 0));
await checkAsync("highlighting text offers Add page: a new note, the highlight links to it, the host opens it", async () => {
  const opened = [], asked = [];
  const ed = mount("Why does sync lag? Look later.", {
    onAddPage: async (text) => { asked.push(text); return "PAGE-1"; }, onFindNotes: async () => [], onLinkNote: (id) => opened.push(id) });
  ed.editor.commands.focus();
  ed.editor.commands.setTextSelection({ from: 1, to: 19 });
  const bubble = () => ed.editor.view.dom.parentElement.querySelector(".mn-bubble");
  assert.ok(bubble(), "menu shows on the highlight");
  assert.deepEqual([...bubble().querySelectorAll("button")].map((b) => b.textContent), ["Add page", "Link to a note…"]);
  bubble().querySelector("button").click();
  await settle();
  assert.deepEqual(asked, ["Why does sync lag?"]);
  assert.equal(ed.getMarkdown().trim(), "[Why does sync lag?](note://PAGE-1) Look later.");
  assert.deepEqual(opened, ["PAGE-1"]);
  assert.equal(bubble(), null);
});
await checkAsync("Link to a note… searches as you type and links the pick", async () => {
  const queries = [];
  const ed = mount("See the answer here", { onAddPage: async () => "X",
    onFindNotes: async (q) => { queries.push(q); return [{ id: "ANS", title: "Sync answer", preview: "Supabase closes idle sockets" }]; } });
  ed.editor.commands.focus();
  ed.editor.commands.setTextSelection({ from: 9, to: 15 });  // "answer"
  const bubble = ed.editor.view.dom.parentElement.querySelector(".mn-bubble");
  bubble.querySelectorAll("button")[1].click();
  const input = bubble.querySelector("input");
  input.value = "sync";
  input.dispatchEvent(new window.Event("input"));
  for (let i = 0; i < 100 && queries.at(-1) !== "sync"; i++) await new Promise((r) => setTimeout(r, 10));  // debounced
  await settle();
  assert.equal(queries.at(-1), "sync");
  assert.equal(bubble.querySelector(".mn-bubble-result").textContent.startsWith("Sync answer"), true);
  input.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  assert.equal(ed.getMarkdown().trim(), "See the [answer](note://ANS) here");
});
await checkAsync("hovering a note link shows its title and first lines", async () => {
  const ed = mount("Question: [why?](note://ANS)", { onNotePreview: async (id) => ({ title: `Answer ${id}`, preview: "Because sockets idle out." }) });
  const a = ed.editor.view.dom.querySelector('a[href="note://ANS"]');
  a.dispatchEvent(new window.MouseEvent("mouseover", { bubbles: true }));
  await new Promise((r) => setTimeout(r, 400));
  const card = ed.editor.view.dom.parentElement.querySelector(".mn-hover");
  assert.ok(card, "card shows");
  assert.equal(card.querySelector("strong").textContent, "Answer ANS");
  a.dispatchEvent(new window.MouseEvent("mouseout", { bubbles: true, relatedTarget: document.body }));
  assert.equal(ed.editor.view.dom.parentElement.querySelector(".mn-hover"), null);
});
await checkAsync("✨ rewrites the whole note and Undo restores it", async () => {
  const seen = [];
  const ed = mount("teh note", { onAI: async (action, md) => { seen.push([action, md]); return "- [ ] the note"; } });
  ai(ed, "checklist");
  await settle();
  assert.deepEqual(seen, [["checklist", "teh note"]]);
  assert.equal(ed.getMarkdown().trim(), "- [ ] the note");
  ed.editor.commands.undo();
  assert.equal(ed.getMarkdown().trim(), "teh note");
});
await checkAsync("✨ on a selection only replaces the selection", async () => {
  const ed = mount("keep this. fix taht.", { onAI: async () => "fix that." });
  ed.editor.commands.setTextSelection({ from: 12, to: 21 });
  ai(ed, "proofread");
  await settle();
  assert.equal(ed.getMarkdown().trim(), "keep this. fix that.");
});
await checkAsync("✨ Add Title puts a heading on top", async () => {
  const ed = mount("body text", { onAI: async () => "My Title" });
  ai(ed, "title");
  await settle();
  assert.equal(ed.getMarkdown().trim(), "# My Title\n\nbody text");
});
await checkAsync("✨ errors show in the status line and leave the note alone", async () => {
  const ed = mount("x", { onAI: async () => { throw new Error("Turn on Apple Intelligence"); } });
  ai(ed, "improve");
  await settle();
  assert.equal(ed.getMarkdown().trim(), "x");
  assert.match(ed.editor.options.element.closest(".mn-editor").querySelector(".mn-ai-status").textContent, /Apple Intelligence/);
  assert.equal(ed.editor.isEditable, true);
});

// Images (D53): files the clipboard or a drop carries are kept by the host; the note gets noteimage:<id>.
const PNG = Uint8Array.from([137, 80, 78, 71, 13, 10, 26, 10]);
const clip = (files, types = {}) => ({ files, getData: (t) => types[t] ?? "" });
const paste = (ed, data) => ed.editor.view.someProp("handlePaste", (f) => f(ed.editor.view, { clipboardData: data }));
const waitFor = async (ok) => { for (let i = 0; i < 50 && !ok(); i++) await new Promise((r) => setTimeout(r, 10)); };
const imageHost = (saved) => ({ onAddImage: async (type, data) => { saved.push([type, data]); return `noteimage:id${saved.length}`; } });
await checkAsync("a pasted screenshot is kept by the host and shows as noteimage:", async () => {
  const saved = [];
  const ed = mount("Before", imageHost(saved));
  ed.editor.commands.setTextSelection(7);
  assert.equal(paste(ed, clip([new window.File([PNG], "image.png", { type: "image/png" })])), true);
  await waitFor(() => saved.length && ed.getMarkdown().includes("noteimage"));
  assert.deepEqual(saved, [["image/png", "iVBORw0KGgo="]]);
  assert.equal(ed.getMarkdown().trim(), "Before\n\n![](noteimage:id1)");
});
await checkAsync("Copy Image on a web page keeps the bytes, not the site's link", async () => {
  const saved = [];
  const ed = mount("", imageHost(saved));
  const file = new window.File([PNG], "image.png", { type: "image/png" });
  assert.equal(paste(ed, clip([file], { "text/html": '<img src="https://example.com/cat.png">' })), true);
  await waitFor(() => ed.getMarkdown().includes("noteimage"));
  assert.equal(ed.getMarkdown().trim(), "![](noteimage:id1)");
});
check("copied text with a picture of itself (Office) pastes as text", () => {
  const saved = [];
  const ed = mount("", imageHost(saved));
  const file = new window.File([PNG], "image.png", { type: "image/png" });
  assert.ok(!paste(ed, clip([file], { "text/plain": "Sales 42" })), "left to the normal paste");
  assert.equal(saved.length, 0);
});
await checkAsync("an image notes can't hold says so and adds nothing", async () => {
  const saved = [];
  const ed = mount("x", imageHost(saved));
  paste(ed, clip([new window.File([PNG], "a.tiff", { type: "image/tiff" })]));
  const root = ed.editor.options.element.closest(".mn-editor");
  await waitFor(() => root.querySelector(".mn-notice"));
  assert.match(root.querySelector(".mn-notice").textContent, /Image not added: .*image\/tiff/);
  assert.equal(saved.length, 0);
  assert.equal(ed.getMarkdown().trim(), "x");
});
await checkAsync("imageURL shows noteimage: sources; one it can't fetch says why", async () => {
  const ed = mount("![](noteimage:aa)\n\n![](noteimage:bb)\n\n![](https://example.com/c.png)", {
    imageURL: async (src) => { if (src.endsWith("bb")) throw new Error("Open NoteAnywhere"); return "blob:x/" + src.slice(10); } });
  await settle();
  const imgs = [...ed.editor.view.dom.querySelectorAll("img")];
  assert.deepEqual(imgs.map((i) => i.getAttribute("src")), ["blob:x/aa", null, "https://example.com/c.png"]);
  assert.equal(imgs[1].alt, "Open NoteAnywhere");
  assert.ok(imgs[1].classList.contains("mn-image-broken"));
  assert.equal(ed.getMarkdown().trim(), "![](noteimage:aa)\n\n![](noteimage:bb)\n\n![](https://example.com/c.png)");
});

await window.happyDOM.close();
console.log(failed ? `${failed} failed` : "all passed");
process.exit(failed ? 1 : 0);
