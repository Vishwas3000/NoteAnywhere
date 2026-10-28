// Runs the built bundle in happy-dom and checks Markdown round-trips and list keyboard behavior.
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import { Window } from "happy-dom";

// Only our own build is evaluated; `npm test` runs node with --disallow-code-generation-from-strings, which also
// proves the bundle needs no eval (CSP-safe for the extension and the app's WebView).
const window = new Window({ settings: { enableJavaScriptEvaluation: true, suppressInsecureJavaScriptEnvironmentWarning: true } });
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
check("shortcuts list is exported", () => assert.ok(MNEditor.shortcuts.length >= 20));

// ✨ menu: the host's reply replaces the whole note (or the selection) as one undoable step; titles go on top.
async function checkAsync(name, fn) {
  try { await fn(); console.log("ok  ", name); } catch (e) { failed++; console.log("FAIL", name, "\n    ", e.message); }
}
const ai = (ed, action) => [...ed.editor.options.element.closest(".mn-editor").querySelectorAll(".mn-ai-menu button")]
  .find((b) => b.textContent === Object.fromEntries(MNEditor.AI_ACTIONS)[action]).click();
const settle = () => new Promise((r) => setTimeout(r, 0));
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

await window.happyDOM.close();
console.log(failed ? `${failed} failed` : "all passed");
process.exit(failed ? 1 : 0);
