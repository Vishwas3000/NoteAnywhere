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
check("a click or tap opens a web link; shift-click and javascript: links don't", () => {
  const opened = [];
  const open = window.open;
  window.open = (href) => opened.push(href);
  const click = (md, event = {}) => {
    const ed = mount(md);
    ed.editor.view.someProp("handleClick", (f) => f(ed.editor.view, 2, { target: ed.editor.view.dom.querySelector("a"), ...event }));
  };
  click("[site](https://example.com)");
  click("[site](https://example.org)", { shiftKey: true });
  try {
    // The schema already drops javascript: links, so hand the click one directly.
    const fake = { closest: () => ({ getAttribute: () => "javascript:alert(1)" }) };
    click("[site](https://example.net)", { target: fake });
  } finally {
    window.open = open;
  }
  assert.deepEqual(opened, ["https://example.com"]);
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
  got = null;  // without ⌘ a click is just a click
  ed.editor.view.someProp("handleClick", (f) => f(ed.editor.view, 0, { metaKey: false, target: el }));
  assert.equal(got, null);
});
check("tapTags: a plain tap on a #tag reports it (the iPhone)", () => {
  let got;
  const ed = mount("plan #ML", { onTag: (t) => (got = t), tapTags: true });
  const el = ed.editor.view.dom.querySelector(".mn-tag");
  ed.editor.view.someProp("handleClick", (f) => f(ed.editor.view, 0, { metaKey: false, target: el }));
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
// The block starting at the first text node containing `text` (a list item, or else the top-level block).
function blockPos(ed, text) {
  let at = -1;
  ed.editor.state.doc.descendants((node, pos) => {
    if (at < 0 && node.isText && node.text.includes(text)) {
      const $pos = ed.editor.state.doc.resolve(pos);
      for (let d = $pos.depth; d > 0 && at < 0; d--) if (/^(listItem|taskItem)$/.test($pos.node(d).type.name)) at = $pos.before(d);
      if (at < 0) at = $pos.before(1);
    }
  });
  return at;
}
const act = (ed, text, label) => MNEditor.blockActions(ed.editor, blockPos(ed, text)).find((a) => a?.label === label).run();
check("the handle menu checks the block's own kind and turns it into another", () => {
  const ed = mount("plain\n\n- item");
  assert.equal(MNEditor.blockActions(ed.editor, blockPos(ed, "plain")).find((a) => a?.label === "Text").hint, "✓");
  assert.equal(MNEditor.blockActions(ed.editor, blockPos(ed, "item")).find((a) => a?.label === "Bulleted list").hint, "✓");
  act(ed, "plain", "Heading 2");
  act(ed, "item", "Numbered list");
  assert.equal(ed.getMarkdown().trim(), "## plain\n\n1. item");
  act(ed, "item", "Text");
  act(ed, "plain", "Quote");
  assert.equal(ed.getMarkdown().trim(), "> plain\n\nitem");
  act(ed, "plain", "Text");
  assert.equal(ed.getMarkdown().trim(), "plain\n\nitem");
  act(ed, "item", "Text");  // already text: nothing changes
  assert.equal(ed.getMarkdown().trim(), "plain\n\nitem");
});
check("the handle menu duplicates and deletes a block; a table only gets those two", () => {
  const ed = mount("- a\n- b\n\nend");
  act(ed, "a", "Duplicate");
  assert.equal(ed.getMarkdown().trim(), "- a\n- a\n- b\n\nend");
  act(ed, "b", "Delete");
  act(ed, "end", "Delete");
  assert.equal(ed.getMarkdown().trim(), "- a\n- a");
  const table = mount("| A | B |\n| --- | --- |\n| 1 | 2 |");
  assert.deepEqual(Array.from(MNEditor.blockActions(table.editor, 0), (a) => a?.label), ["Duplicate", "Delete"]);
});
check("the handle menu's search finds actions by name or other words, without lines", () => {
  const ed = mount("plain");
  const all = MNEditor.blockActions(ed.editor, blockPos(ed, "plain"));
  const labels = (q) => Array.from(MNEditor.matchActions(all, q), (a) => a?.label);
  assert.equal(MNEditor.matchActions(all, "  ").length, all.length);
  assert.deepEqual(labels("quo"), ["Quote"]);
  assert.deepEqual(labels("remove"), ["Delete"]);
  assert.deepEqual(labels("head"), ["Heading 1", "Heading 2", "Heading 3"]);
  assert.deepEqual(labels("zzz"), []);
});
check("the # menu's search: case aside, the tag itself, then tags starting with it, then ones containing it; 8 at most", () => {
  const tags = [{ tag: "homework", count: 9 }, { tag: "workshop", count: 5 }, { tag: "work", count: 2 }, { tag: "bug", count: 1 }];
  const names = (q) => Array.from(MNEditor.matchTags(tags, q), (t) => t.tag);
  assert.deepEqual(names("WORK"), ["work", "workshop", "homework"]);
  assert.deepEqual(names("or"), ["homework", "workshop", "work"]);  // the host's order, most used first
  assert.deepEqual(names(""), ["homework", "workshop", "work", "bug"]);
  assert.deepEqual(names("zzz"), []);
  assert.equal(MNEditor.matchTags(Array.from({ length: 20 }, (_, i) => ({ tag: `t${i}`, count: 1 })), "t").length, 8);
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
check("a month and day means the next one: @dec9th, @9 dec, @December 25; impossible days stay text", () => {
  const wed = new Date(2026, 9, 28);
  assert.equal(MNEditor.dayFor("dec9th", wed), "2026-12-09");
  assert.equal(MNEditor.dayFor("9 Dec", wed), "2026-12-09");
  assert.equal(MNEditor.dayFor("December 25", wed), "2026-12-25");
  assert.equal(MNEditor.dayFor("oct28", wed), "2026-10-28");
  assert.equal(MNEditor.dayFor("jan 1st", wed), "2027-01-01"); // already past this year
  assert.equal(MNEditor.dayFor("feb30", wed), null);
  const ed = mount("");
  for (const ch of "Party @dec9th and @feb30 ") {
    const { from, to } = ed.editor.state.selection;
    if (!ed.editor.view.someProp("handleTextInput", (f) => f(ed.editor.view, from, to, ch))) ed.editor.commands.insertContent(ch);
  }
  assert.equal(ed.getMarkdown().trim(), `Party @${MNEditor.dayFor("dec9th")} and @feb30`);
});
check("the @ menu reads a typed day: @jan7 shows that date, Return picks it", () => {
  const ed = mount("Flight ");
  ed.editor.commands.focus("end");
  ed.editor.commands.insertContent("@jan7");
  const items = () => [...ed.editor.view.dom.parentElement.querySelectorAll(".mn-at-menu .mn-at-item")];
  const day = MNEditor.dayFor("jan7");
  assert.equal(items().length, 1);
  assert.ok(items()[0].textContent.includes(String(new Date(`${day}T00:00`).getFullYear())), items()[0].textContent);
  ed.editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  assert.equal(ed.getMarkdown().trim(), `Flight @${day}`);
  ed.editor.commands.insertContent(" @dec 9");
  assert.equal(items().length, 1, "a space between month and day keeps the menu");
  ed.editor.commands.insertContent(" @feb30");
  assert.equal(items().length, 0, "no menu for a day that doesn't exist");
});
check("the @ menu answers every letter on the way to a date", () => {
  const ed = mount("Trip ");
  ed.editor.commands.focus("end");
  const labels = () => [...ed.editor.view.dom.parentElement.querySelectorAll(".mn-at-menu .mn-at-item")].map((i) => i.firstChild.textContent);
  const steps = [..."@jan 7"].map((ch) => { ed.editor.commands.insertContent(ch); return labels(); });
  const jan7 = new Date(`${MNEditor.dayFor("jan 7")}T00:00`).toLocaleDateString(undefined, { weekday: "long", day: "numeric", month: "long", year: "numeric" });
  // "@", "@j", "@ja", "@jan", "@jan " (the space keeps it), "@jan 7"
  assert.deepEqual(steps.slice(1), [["January", "June", "July"], ["January"], ["January"], ["January"], [jan7]]);
  assert.deepEqual(labels().length, 1);
  // Picking a month types it and waits for the day; day first works too.
  const ed2 = mount("x ");
  ed2.editor.commands.focus("end");
  ed2.editor.commands.insertContent("@ju");
  ed2.editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", { key: "Enter", bubbles: true, cancelable: true }));
  assert.equal(ed2.getMarkdown().trim(), "x @jun");
  ed2.editor.commands.insertContent(" @7 ma");
  assert.equal([...ed2.editor.view.dom.parentElement.querySelectorAll(".mn-at-menu .mn-at-item")].length, 2, "7 March and 7 May");
});
check("an event's own colour tints its chip, hides in the chip and survives a round trip", () => {
  const md = "Dentist @2026-11-05{red} and gym @2026-11-06";
  const ed = mount(md, { datePattern: "d MMM yyyy" });
  assert.equal(ed.getMarkdown().trim(), md);
  const chips = [...ed.editor.view.dom.querySelectorAll(".mn-date")];
  assert.deepEqual(chips.map((c) => c.textContent), ["5 Nov 2026", "6 Nov 2026"]);
  assert.deepEqual(chips.map((c) => c.classList.contains("mn-c-red")), [true, false]);
  assert.equal(chips[0].dataset.day, "2026-11-05");
  // A range's colour covers both ends, whichever end carries it; a separate date nearby doesn't take it.
  const range = mount("Trip @2026-11-03{blue} - @2026-11-16, call @2026-11-20\n\nGoa @2026-12-01 to @2026-12-04{green}");
  assert.deepEqual([...range.editor.view.dom.querySelectorAll(".mn-date")].map((c) => [...c.classList].find((k) => k.startsWith("mn-c-")) ?? ""),
    ["mn-c-blue", "mn-c-blue", "", "mn-c-green", "mn-c-green"]);
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
  assert.equal(MNEditor.formatDay("2026-10-30", "EEE, d MMM yyyy"), "Fri, 30 Oct 2026");
  assert.equal(MNEditor.formatDay("2026-10-30", "d MMMM yyyy"), "30 October 2026");
  assert.equal(MNEditor.formatDay("2026-10-30", "EEEE, d MMMM", 2026), "Friday, 30 October");
  assert.equal(MNEditor.formatDay("2027-01-05", "EEEE, d MMMM", 2026), "Tuesday, 5 January 2027");
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
  // Typing next goes after the image instead of replacing it.
  ed.editor.commands.insertContent("After");
  assert.equal(ed.getMarkdown().trim(), "Before\n\n![](noteimage:id1)\n\nAfter");
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

// Pasted links: Link · Mention · Card.
const MENTION_MD = 'See [Quick Start \\[React\\]](https://react.dev/learn "mention noteimage:ic1") today';
const CARD_MD = "> [!bookmark] [Quick Start – React](https://react.dev/learn)\n> Welcome to the React docs!\n> ![](noteimage:ic1 \"icon\") ![](noteimage:im1)";
check("a mention round-trips and shows its icon and title", () => {
  const ed = mount(MENTION_MD);
  assert.equal(ed.getMarkdown().trim(), MENTION_MD);
  const a = ed.editor.view.dom.querySelector("a.mn-mention");
  assert.equal(a.textContent, "Quick Start [React]");
  assert.equal(a.querySelector("img").getAttribute("src"), "noteimage:ic1");
});
check("a card round-trips; one with no description or pictures too", () => {
  roundTrip(CARD_MD);
  roundTrip("> [!bookmark] [example.com](https://example.com/a%20b)");
  const card = mount(CARD_MD).editor.view.dom.querySelector("a.mn-card");
  assert.equal(card.getAttribute("href"), "https://react.dev/learn");
  assert.equal(card.querySelector("strong").textContent, "Quick Start – React");
  assert.equal(card.querySelector(".mn-card-desc").textContent, "Welcome to the React docs!");
  assert.equal(card.querySelector(".mn-card-site").textContent, "react.dev");
});
check("an ordinary quote and link stay as they are", () => roundTrip("> a quote with [a link](https://example.com)"));
const hit = (ed, k) => ed.editor.view.dom.dispatchEvent(new window.KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true }));
const URL_CLIP = (url) => clip([], { "text/plain": url });
const previewHost = (asked) => ({ onLinkPreview: async (url) => {
  asked.push(url);
  return { title: "Quick Start – React", description: "Welcome to the React docs!", icon: "noteimage:ic1", image: "noteimage:im1" };
} });
const menuItems = (ed) => [...ed.editor.options.element.closest(".mn-editor").querySelectorAll(".mn-at-item")].map((i) => i.firstChild.textContent);
await checkAsync("pasting a lone URL inserts a link and offers Link, Mention, Card; Enter keeps the link", async () => {
  const asked = [];
  const ed = mount("", previewHost(asked));
  assert.equal(paste(ed, URL_CLIP("https://react.dev/learn")), true);
  assert.deepEqual(menuItems(ed), ["Link", "Mention", "Card"]);
  hit(ed, "Enter");
  await settle();
  assert.deepEqual(menuItems(ed), []);
  assert.deepEqual(asked, []);
  assert.match(ed.getMarkdown(), /\]\(https:\/\/react\.dev\/learn\)/);
});
await checkAsync("Mention asks the host and puts the title in the line", async () => {
  const asked = [];
  const ed = mount("See ", previewHost(asked));
  ed.editor.commands.setTextSelection(5);
  paste(ed, URL_CLIP("https://react.dev/learn"));
  hit(ed, "ArrowDown");
  hit(ed, "Enter");
  await waitFor(() => ed.getMarkdown().includes("mention"));
  assert.deepEqual(asked, ["https://react.dev/learn"]);
  assert.equal(ed.getMarkdown().trim(), 'See [Quick Start – React](https://react.dev/learn "mention noteimage:ic1")');
});
await checkAsync("Card replaces a link alone on its line; typing instead keeps the link", async () => {
  const ed = mount("", previewHost([]));
  paste(ed, URL_CLIP("https://react.dev/learn"));
  hit(ed, "ArrowDown");
  hit(ed, "ArrowDown");
  hit(ed, "Enter");
  await waitFor(() => ed.getMarkdown().includes("bookmark"));
  assert.equal(ed.getMarkdown().trim(), CARD_MD);
  const typed = mount("", previewHost([]));
  paste(typed, URL_CLIP("https://example.com"));
  hit(typed, "a");
  assert.deepEqual(menuItems(typed), []);
});
await checkAsync("a preview that fails says why and leaves the link; code and text pastes get no menu", async () => {
  const ed = mount("", { onLinkPreview: async () => { throw new Error("The site didn't answer."); } });
  paste(ed, URL_CLIP("https://example.com"));
  hit(ed, "ArrowDown");
  hit(ed, "Enter");
  await waitFor(() => ed.editor.options.element.closest(".mn-editor").querySelector(".mn-notice"));
  assert.equal(ed.editor.options.element.closest(".mn-editor").querySelector(".mn-notice")?.textContent, "Preview not added: The site didn't answer.");
  assert.match(ed.getMarkdown(), /\]\(https:\/\/example\.com\)/);
  const code = mount("```\nx\n```", previewHost([]));
  code.editor.commands.setTextSelection(2);
  assert.ok(!paste(code, URL_CLIP("https://example.com")));
  assert.ok(!paste(mount("", previewHost([])), URL_CLIP("see https://example.com")));
});

// The "#" menu: the tags in use come from the host (onFindTags) and are narrowed in the editor.
const TAGS = [{ tag: "noteanywhere", count: 3 }, { tag: "bug", count: 1 }];
const tagMenu = (ed) => ed.editor.view.dom.parentElement.querySelector('.mn-at-menu[aria-label="Tags"]');
const tagLabels = (ed) => [...(tagMenu(ed)?.querySelectorAll(".mn-at-item") ?? [])].map((i) => i.firstChild.textContent);
const typeIn = (ed, text) => { for (const ch of text) ed.editor.commands.insertContent(ch); };
// Not commands.focus(): it redraws a frame later, which would hide a menu that doesn't redraw for the host's answer.
const caretAt = (ed, pos = ed.editor.state.doc.content.size) => ed.editor.commands.setTextSelection(pos);
await checkAsync("typing # offers the tags in use; Return, Tab or a click types the tag and a space; Esc closes", async () => {
  const asked = [];
  const ed = mount("Plan ", { onFindTags: async (q) => { asked.push(q); return TAGS; } });
  caretAt(ed);
  typeIn(ed, "#no");
  await settle();
  assert.deepEqual(tagLabels(ed), ["#noteanywhere"]);
  assert.equal(tagMenu(ed).querySelector(".mn-at-hint").textContent, "3");
  assert.deepEqual(asked, [""], "asked once, when # was typed; the rest is narrowed here");
  hit(ed, "Enter");
  assert.equal(ed.editor.state.doc.textContent, "Plan #noteanywhere ");
  assert.deepEqual(tagLabels(ed), []);
  typeIn(ed, "#");
  await settle();
  assert.deepEqual(tagLabels(ed), ["#noteanywhere", "#bug"]);
  hit(ed, "ArrowDown");
  hit(ed, "Tab");
  typeIn(ed, "#B");
  await settle();
  tagMenu(ed).querySelector(".mn-at-item").dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, cancelable: true }));
  typeIn(ed, "#");
  await settle();
  hit(ed, "Escape");
  assert.deepEqual(tagLabels(ed), []);
  assert.equal(ed.editor.state.doc.textContent, "Plan #noteanywhere #bug #bug #");
  typeIn(ed, " #zz");
  await settle();
  assert.deepEqual(tagLabels(ed), [], "a new tag matches nothing: no menu");
});
await checkAsync("no # menu in inline code, a link or a word, without onFindTags, or for a tag the caret lands on", async () => {
  const host = { onFindTags: async () => TAGS };
  const at = (md, pos, options = host) => { const ed = mount(md, options); caretAt(ed, pos); return ed; };
  const eds = [at("`a  b`", 3), at("[a  b](https://example.com)", 3), at("a b", 3)];  // the caret after "a "
  for (const ed of eds) typeIn(ed, "#no");
  const bare = at("Plan", 5, {});
  typeIn(bare, " #no");
  const landed = at("Plan #noteanywhere", 19);  // right after the tag: Return must still start a new line
  await settle();
  assert.deepEqual([...eds, bare].map(tagLabels), [[], [], [], []]);
  assert.equal(bare.editor.state.doc.textContent, "Plan #no");
  assert.deepEqual(tagLabels(landed), []);
  hit(landed, "Enter");
  assert.deepEqual([landed.editor.state.doc.childCount, landed.editor.state.doc.firstChild.textContent], [2, "Plan #noteanywhere"]);
  // The host's text ending in a tag (the Mac's + Tag) leaves the caret after it, without a menu.
  landed.setMarkdown("Plan #noteanywhere #bug");
  await settle();
  assert.equal(landed.editor.state.selection.from, landed.editor.state.doc.content.size - 1, "caret after #bug");
  assert.deepEqual(tagLabels(landed), []);
});
await checkAsync("only the latest answer to the # menu counts; a failed one says why", async () => {
  const replies = [];
  const ed = mount("", { onFindTags: () => new Promise((resolve) => replies.push(resolve)) });
  caretAt(ed);
  typeIn(ed, "#b #");  // two "#"s, two questions
  replies[1]([{ tag: "bug", count: 2 }]);
  await settle();
  replies[0]([{ tag: "old", count: 9 }]);  // the first answer, arriving late
  await settle();
  assert.deepEqual(tagLabels(ed), ["#bug"]);
  const failing = mount("", { onFindTags: async () => { throw new Error("The notes aren't loaded."); } });
  caretAt(failing);
  typeIn(failing, "#");
  const root = failing.editor.options.element.closest(".mn-editor");
  await waitFor(() => root.querySelector(".mn-notice"));
  assert.equal(root.querySelector(".mn-notice")?.textContent, "Tags not suggested: The notes aren't loaded.");
});

await window.happyDOM.close();
console.log(failed ? `${failed} failed` : "all passed");
process.exit(failed ? 1 : 0);
