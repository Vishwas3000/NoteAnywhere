import { Editor, Extension, InputRule } from "@tiptap/core";
import { NodeSelection, Plugin, TextSelection } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import StarterKit from "@tiptap/starter-kit";
import { TaskItem, TaskList } from "@tiptap/extension-list";
import { TableKit } from "@tiptap/extension-table";
import Image from "@tiptap/extension-image";
import { Placeholder } from "@tiptap/extensions";
import { Markdown } from "@tiptap/markdown";
import { BlockMath, InlineMath } from "@tiptap/extension-mathematics";
import { shortcuts } from "./shortcuts.js";
import "./style.css";

export { shortcuts };

// Stroke icons in a 24 px box; a few paths follow Lucide (ISC license).
const icon = (paths) =>
  `<svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths}</svg>`;
const text = (t, style = "") => `<span class="mn-glyph" style="${style}">${t}</span>`;
const LINES = (x) => `<path d="M${x} 6h11M${x} 12h11M${x} 18h11"/>`;

// [icon, name, command, active state]; null starts a new group.
const TOOLBAR = [
  [text("B", "font-weight:700"), "Bold", (c) => c.toggleBold(), "bold"],
  [text("I", "font-style:italic;font-family:Georgia,serif"), "Italic", (c) => c.toggleItalic(), "italic"],
  [text("S", "text-decoration:line-through"), "Strikethrough", (c) => c.toggleStrike(), "strike"],
  [icon('<path d="m16 18 6-6-6-6M8 6l-6 6 6 6"/>'), "Inline code", (c) => c.toggleCode(), "code"],
  null,
  [text("H1"), "Heading 1", (c) => c.toggleHeading({ level: 1 }), ["heading", { level: 1 }]],
  [text("H2"), "Heading 2", (c) => c.toggleHeading({ level: 2 }), ["heading", { level: 2 }]],
  null,
  [icon(LINES(9) + '<circle cx="4" cy="6" r="1"/><circle cx="4" cy="12" r="1"/><circle cx="4" cy="18" r="1"/>'),
    "Bullet list", (c) => c.toggleBulletList(), "bulletList"],
  [icon(LINES(10) + '<path d="M4 4h1v5M4 9h2M6 19H4c0-1 2-2 2-3s-1-1.5-2-1"/>'), "Numbered list", (c) => c.toggleOrderedList(), "orderedList"],
  [icon('<rect x="3" y="4" width="6" height="6" rx="1.5"/><path d="m3 17 2 2 4-4M13 7h8M13 17h8"/>'), "Checklist", (c) => c.toggleTaskList(), "taskList"],
  [icon('<path d="M17 6H3M21 12H8M21 18H8M3 12v6"/>'), "Quote", (c) => c.toggleBlockquote(), "blockquote"],
  null,
  [icon('<rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 9h18M3 15h18M12 3v18"/>'), "Insert table",
    (c) => c.insertTable({ rows: 3, cols: 3, withHeaderRow: true }), "table"],
];
// Blocks you can drag or move, like Notion: a list item (checklist items too) or else a top-level block.
const ITEMS = new Set(["listItem", "taskItem"]);
function blockAround($pos) {
  for (let d = $pos.depth; d > 0; d--) if (ITEMS.has($pos.node(d).type.name)) return d;
  return $pos.depth > 0 ? 1 : 0;
}

/** ⌘⇧↑ / ⌘⇧↓: swap the block holding the cursor with its neighbour, keeping the cursor where it was in it. */
function moveBlock(editor, dir) {
  const { state, view } = editor;
  const $from = state.selection.$from;
  const depth = blockAround($from);
  if (!depth) return false;
  const parent = $from.node(depth - 1), index = $from.index(depth - 1);
  if (index + dir < 0 || index + dir >= parent.childCount) return true; // at the edge: nothing to do, but don't leak the key
  const node = $from.node(depth), start = $from.before(depth), offset = $from.pos - start;
  const neighbour = parent.child(index + dir);
  const to = dir < 0 ? start - neighbour.nodeSize : start + neighbour.nodeSize;
  const tr = state.tr.delete(start, start + node.nodeSize).insert(to, node);
  tr.setSelection(TextSelection.near(tr.doc.resolve(to + offset)));
  view.dispatch(tr.scrollIntoView());
  return true;
}

/** The ⋮⋮ handle left of the block under the pointer. Dragging it moves the block between blocks, like Notion. */
function dragHandle() {
  let handleView;
  return Extension.create({
    name: "mnDragHandle",
    addProseMirrorPlugins: () => [new Plugin({
      view: (view) => (handleView = dragHandleView(view)),
      props: { handleDrop: (view, event) => handleView?.drop(event) ?? false },
    })],
  });
}

function dragHandleView(view) {
  const handle = Object.assign(document.createElement("div"), { className: "mn-drag", draggable: true, textContent: "⋮⋮",
    title: "Drag to move · ⌘⇧↑ ⌘⇧↓" });
  handle.setAttribute("aria-hidden", "true"); // keyboard users have ⌘⇧↑/↓
  const line = Object.assign(document.createElement("div"), { className: "mn-drop" });
  let current = null, dragged = null;

  // TipTap mounts the editor's DOM after creating the view, so the handle joins it once it's in place.
  const attach = () => {
    const body = view.dom.parentElement;
    if (body && handle.parentElement !== body) body.append(handle);
    return body;
  };
  // The block under the pointer at `depth` (or the list item / top-level block when depth is null).
  const blockAt = (event, item) => {
    const content = view.dom.getBoundingClientRect();
    const found = view.posAtCoords({ left: Math.max(event.clientX, content.left + 30), top: event.clientY });
    if (!found) return null;
    const $pos = view.state.doc.resolve(found.pos);
    const depth = item === false ? Math.min($pos.depth, 1) : blockAround($pos);
    const pos = depth ? $pos.before(depth) : found.inside;
    const dom = pos >= 0 && view.nodeDOM(pos);
    return dom instanceof HTMLElement ? { pos, node: view.state.doc.nodeAt(pos), dom, box: dom.getBoundingClientRect() } : null;
  };
  // Where a dragged block lands: before or after the block under the pointer; list items only between list items.
  const target = (event) => {
    const block = blockAt(event, dragged.item ? null : false);
    if (!block) return null;
    const after = event.clientY > block.box.top + block.box.height / 2;
    return { to: after ? block.pos + block.node.nodeSize : block.pos, y: after ? block.box.bottom : block.box.top, box: block.box };
  };
  const finish = () => {
    view.dragging = null;
    dragged = null;
    line.remove();
    handle.classList.remove("on");
  };

  view.dom.addEventListener("mousemove", (event) => {
    const body = attach(), block = body && blockAt(event, null);
    if (!block) return;
    current = block.pos;
    const frame = body.getBoundingClientRect();
    const lineHeight = parseFloat(getComputedStyle(block.dom).lineHeight) || 20;
    handle.style.top = `${block.box.top - frame.top + Math.max(0, (Math.min(lineHeight, block.box.height) - 22) / 2)}px`;
    // Bullets and numbers sit outside the <li>, so a list item's handle goes left of its list instead.
    const left = block.dom.tagName === "LI" ? block.dom.parentElement.getBoundingClientRect().left : block.box.left;
    handle.style.left = `${Math.max(0, left - frame.left - 20)}px`;
    handle.classList.add("on");
  });
  view.dom.addEventListener("mouseleave", (event) => { if (event.relatedTarget !== handle) handle.classList.remove("on"); });
  handle.addEventListener("dragstart", (event) => {
    if (current == null) return;
    const selection = NodeSelection.create(view.state.doc, current);
    view.dispatch(view.state.tr.setSelection(selection));
    view.dragging = { slice: selection.content(), move: true };
    dragged = { from: current, size: selection.node.nodeSize, slice: selection.content(), item: ITEMS.has(selection.node.type.name) };
    event.dataTransfer.effectAllowed = "move";
    event.dataTransfer.setData("text/plain", selection.node.textContent);
    event.dataTransfer.setDragImage(view.nodeDOM(current), 0, 0);
  });
  handle.addEventListener("dragend", finish);
  view.dom.addEventListener("dragover", (event) => {
    const spot = dragged && target(event), body = attach();
    if (!spot || !body) return line.remove();
    event.preventDefault();
    const frame = body.getBoundingClientRect();
    Object.assign(line.style, { top: `${spot.y - frame.top - 1}px`, left: `${spot.box.left - frame.left}px`, width: `${spot.box.width}px` });
    body.append(line);
  });
  view.dom.addEventListener("dragleave", (event) => { if (!view.dom.contains(event.relatedTarget)) line.remove(); });
  attach();

  return {
    update: attach,
    destroy: () => { handle.remove(); line.remove(); },
    drop(event) {
      const spot = dragged && target(event);
      if (!spot) return false;
      const { from, size, slice } = dragged;
      if (spot.to < from || spot.to > from + size) { // dropped onto itself: nothing moves
        const tr = view.state.tr.delete(from, from + size);
        const to = tr.mapping.map(spot.to);
        tr.replaceRange(to, to, slice);
        tr.setSelection(TextSelection.near(tr.doc.resolve(Math.min(to + 1, tr.doc.content.size))));
        view.dispatch(tr.scrollIntoView());
      }
      finish();
      return true;
    },
  };
}

// Obsidian-style #tags, same rule as Note.tags in Swift: needs a letter, may nest with "/".
const TAG = /(^|[\s(\[{,;:!?])#([\p{L}\p{N}_\-/]*[\p{L}_\-][\p{L}\p{N}_\-/]*)/gu;

/** Highlights #tags as you type (outside code and links); ⌘-click one to see every note with it (onTag). */
function tagHighlighter(onTag) {
  return Extension.create({
    name: "mnTags",
    addProseMirrorPlugins: () => [new Plugin({
      props: {
        decorations(state) {
          const found = [];
          state.doc.descendants((node, pos, parent) => {
            if (parent?.type.name === "codeBlock" || !node.isText || node.marks.some((m) => m.type.name === "code" || m.type.name === "link")) return;
            for (const m of node.text.matchAll(TAG)) {
              const from = pos + m.index + m[1].length;
              found.push(Decoration.inline(from, from + 1 + m[2].length, {
                class: "mn-tag", "data-tag": m[2].toLowerCase().replace(/^\/+|\/+$/g, ""),
                title: onTag ? "⌘-click to see every note with this tag" : "",
              }));
            }
          });
          return DecorationSet.create(state.doc, found);
        },
        handleClick(view, pos, event) {
          const tag = event.metaKey && event.target.closest?.(".mn-tag")?.dataset.tag;
          if (!tag || !onTag) return false;
          onTag(tag);
          return true;
        },
      },
    })],
  });
}

export const AI_ACTIONS = [
  ["proofread", "Fix Spelling & Grammar"],
  ["improve", "Make Clearer"],
  ["shorten", "Make Shorter"],
  ["checklist", "Turn into Checklist"],
  ["title", "Add Title"],
];
const SPARKLE = icon('<path d="M12 3l1.9 5.1L19 10l-5.1 1.9L12 17l-1.9-5.1L5 10l5.1-1.9z"/><path d="M19 15l.7 1.8 1.8.7-1.8.7L19 20l-.7-1.8-1.8-.7 1.8-.7z"/>');

/** The ✨ button and its menu. Works on the selection if there is one, otherwise on the whole note. */
function aiMenu(editor, onAI) {
  const wrap = Object.assign(document.createElement("div"), { className: "mn-ai" });
  const button = Object.assign(document.createElement("button"), { type: "button", innerHTML: SPARKLE, title: "Apple Intelligence" });
  button.setAttribute("aria-label", "Apple Intelligence");
  button.setAttribute("aria-haspopup", "menu");
  button.setAttribute("aria-expanded", "false");
  const menu = Object.assign(document.createElement("div"), { className: "mn-ai-menu", hidden: true });
  menu.setAttribute("role", "menu");
  const status = Object.assign(document.createElement("div"), { className: "mn-ai-status" });
  status.setAttribute("role", "status");
  const items = AI_ACTIONS.map(([action, label]) => {
    const item = Object.assign(document.createElement("button"), { type: "button", textContent: label });
    item.setAttribute("role", "menuitem");
    item.onmousedown = (e) => e.preventDefault(); // keep the editor's selection
    item.onclick = () => run(action);
    item.onmouseenter = () => item.focus(); // hover and keyboard share one highlight
    return item;
  });
  const footer = Object.assign(document.createElement("div"), { className: "mn-ai-footer", textContent: "Apple Intelligence · on this Mac" });
  menu.append(...items, footer);
  wrap.append(button, menu, status);

  const toggle = (open) => {
    menu.hidden = !open;
    button.setAttribute("aria-expanded", String(open));
    // A host sizing the editor to its content (onHeight) must grow while the menu hangs below a short note.
    wrap.parentElement.style.minHeight = open ? `${menu.offsetTop + menu.offsetHeight + 4}px` : "";
    if (open) items[0].focus();
  };
  button.onmousedown = (e) => e.preventDefault();
  button.onclick = () => toggle(menu.hidden);
  menu.onkeydown = (e) => {
    const i = items.indexOf(document.activeElement);
    if (e.key === "Escape") { toggle(false); editor.commands.focus(); }
    else if (e.key === "ArrowDown") items[(i + 1) % items.length].focus();
    else if (e.key === "ArrowUp") items[(i - 1 + items.length) % items.length].focus();
    else return;
    e.preventDefault();
  };
  wrap.addEventListener("focusout", (e) => { if (!wrap.contains(e.relatedTarget)) toggle(false); });

  async function run(action) {
    toggle(false);
    const { from, to, empty } = editor.state.selection;
    const whole = empty || action === "title";
    const input = whole ? editor.getMarkdown() : editor.state.doc.textBetween(from, to, "\n");
    const before = editor.state.doc;
    wrap.classList.add("busy");
    status.textContent = "Writing…";
    editor.setEditable(false); // the result replaces this exact text
    try {
      const result = await onAI(action, input);
      editor.setEditable(true);
      if (!editor.state.doc.eq(before)) throw new Error("The note changed meanwhile, so nothing was replaced.");
      const chain = editor.chain().focus();
      if (action === "title") chain.insertContentAt(0, `# ${result.replace(/^#+\s*/, "")}`, { contentType: "markdown" });
      else if (whole) chain.insertContentAt({ from: 0, to: editor.state.doc.content.size }, result, { contentType: "markdown" });
      // A one-line answer stays inline; parsing it as Markdown would split the paragraph around it.
      else if (!result.includes("\n")) chain.insertContentAt({ from, to }, { type: "text", text: result });
      else chain.insertContentAt({ from, to }, result, { contentType: "markdown" });
      chain.run();
      status.textContent = "";
    } catch (e) {
      editor.setEditable(true);
      status.textContent = e?.message || String(e);
      setTimeout(() => { status.textContent = ""; }, 5000);
    } finally {
      wrap.classList.remove("busy");
    }
  }
  return wrap;
}

const CALENDAR_ICON = icon('<rect x="3" y="4" width="18" height="18" rx="2"/><path d="M16 2v4M8 2v4M3 10h18"/>');

const isoDay = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
const WEEKDAYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
/** "today", "tomorrow", "yesterday", or a weekday (its next one, today included) as yyyy-mm-dd. */
export function dayFor(word, now = new Date()) {
  const d = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  const w = word.toLowerCase();
  if (w === "tomorrow") d.setDate(d.getDate() + 1);
  else if (w === "yesterday") d.setDate(d.getDate() - 1);
  else if (w !== "today") d.setDate(d.getDate() + ((WEEKDAYS.indexOf(w.slice(0, 3)) - d.getDay() + 7) % 7));
  return isoDay(d);
}

// Same rule as Note.dates in Swift: "@2026-10-30", or Obsidian Tasks' "📅 2026-10-30".
const DATE = /(^|[\s(\[])((?:@|📅\s?)(\d{4}-\d{2}-\d{2}))(?![\w-])/gu;
const SHORTHAND = /(?:^|\s)(@(today|tomorrow|yesterday|mon(?:day)?|tue(?:s|sday)?|wed(?:nesday)?|thu(?:rs|rsday)?|fri(?:day)?|sat(?:urday)?|sun(?:day)?))\s$/i;

/** "2026-10-30" in a date pattern from the host ("dd/MM/yyyy", "MM/dd/yyyy", "dd.MM.yyyy", …). */
export const formatDay = (iso, pattern) => {
  const [y, m, d] = iso.split("-");
  return pattern.replace(/d+|M+|y+/g, (t) => (t[0] === "d" ? d : t[0] === "M" ? m : y));
};

/**
 * Date chips (⌘-click opens the day via onDate), "@today " / "@fri " typed into real dates, and an "@" menu.
 * With a datePattern, a chip shows its day that way ("30/10/2026"); the note keeps "@2026-10-30", and the caret
 * inside a chip shows that source for editing, like Obsidian's live preview.
 */
function dates(onDate, pickDate, datePattern) {
  return Extension.create({
    name: "mnDates",
    addInputRules: () => [new InputRule({
      find: SHORTHAND,
      handler: ({ state, range, match }) => {
        const start = range.from + match[0].indexOf(match[1]);
        state.tr.insertText(`@${dayFor(match[2])} `, start, range.to);
      },
    })],
    addProseMirrorPlugins: () => [atMenu(pickDate), new Plugin({
      props: {
        decorations(state) {
          const found = [];
          state.doc.descendants((node, pos, parent) => {
            if (parent?.type.name === "codeBlock" || !node.isText || node.marks.some((m) => m.type.name === "code")) return;
            for (const m of node.text.matchAll(DATE)) {
              const day = new Date(`${m[3]}T00:00`);
              if (Number.isNaN(day.getTime()) || isoDay(day) !== m[3]) continue; // 2026-02-30 isn't a day
              const from = pos + m.index + m[1].length, to = from + m[2].length;
              const title = day.toLocaleDateString(undefined, { weekday: "long", day: "numeric", month: "long", year: "numeric" })
                + (onDate ? " · ⌘-click to open this day" : "");
              const { selection } = state;
              if (!datePattern || (selection.from < to && selection.to > from)) {
                found.push(Decoration.inline(from, to, { class: "mn-date", "data-day": m[3], title }));
                continue;
              }
              // The source stays in the text (shrunk to nothing, so the caret can still enter it); a widget shows the day.
              const label = m[2].replace(m[3], formatDay(m[3], datePattern)).replace(/^@/, "");
              found.push(Decoration.inline(from, to, { class: "mn-date-src" }), Decoration.widget(from, () => {
                const chip = Object.assign(document.createElement("span"), { className: "mn-date", textContent: label, title });
                chip.dataset.day = m[3];
                return chip;
              }, { side: 1, key: `${m[3]}|${label}` }));
            }
          });
          return DecorationSet.create(state.doc, found);
        },
        handleClick(view, pos, event) {
          const day = event.metaKey && event.target.closest?.(".mn-date")?.dataset.day;
          if (!day || !onDate) return false;
          onDate(day);
          return true;
        },
      },
    })],
  });
}

// Maths as notes, Obsidian and AI chats write it: $…$ or \(…\) inline, $$…$$ or \[…\] on a line of its own; saved
// as $…$ and $$…$$. A single "$" opens only before a non-space and closes only after one, not before a digit
// (pandoc's rule), so "$5 and $10" stays text.
const DOLLAR = String.raw`\$(?![\s$])((?:[^$\n\\]|\\.)*?)(?<![\s\\])\$(?!\d)`;
const INLINE_MATH = new RegExp(String.raw`\\\((.+?)\\\)|\\\[(.+?)\\\]|\$\$([^$\n]+?)\$\$|` + DOLLAR, "g");
const INLINE_MATH_START = new RegExp(`^(?:${INLINE_MATH.source})`);
const BLOCK_MATH = /^(?:\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\])[ \t]*(?:\n|$)/;
const latexOf = (m) => (m[1] ?? m[2] ?? m[3] ?? m[4] ?? "").trim();

/**
 * Formulas render with KaTeX as MathML, which WebKit and Chrome draw themselves (no fonts to ship). The Markdown
 * tokenizers keep the LaTeX exactly as written; text that reads as maths (pasted, typed, or saved before maths
 * worked) becomes a formula once the caret leaves it, and clicking a formula gives its source back to edit.
 */
function maths(getEditor) {
  const katexOptions = { output: "mathml", throwOnError: false };
  const edit = (node, pos, inline) => {
    const latex = node.attrs.latex.replace(/\s*\n\s*/g, " ");
    const source = inline ? `$${latex}$` : `$$${latex}$$`;
    const content = { type: "text", text: source };
    getEditor().chain().focus()
      .insertContentAt({ from: pos, to: pos + node.nodeSize }, inline ? content : { type: "paragraph", content: [content] })
      .setTextSelection(pos + (inline ? 1 : 3) + latex.length)  // just before the closing $
      .run();
  };
  return [
    InlineMath.extend({
      markdownTokenizer: {
        name: "inlineMath",
        level: "inline",
        start: (src) => src.search(/\\[([]|\$/),
        tokenize: (src) => {
          const m = INLINE_MATH_START.exec(src);
          return m && latexOf(m) ? { type: "inlineMath", raw: m[0], latex: latexOf(m) } : undefined;
        },
      },
    }).configure({ katexOptions, onClick: (node, pos) => edit(node, pos, true) }),
    BlockMath.extend({
      markdownTokenizer: {
        name: "blockMath",
        level: "block",
        start: (src) => src.search(/^(?:\$\$|\\\[)/m),  // only at a line's start, so paragraphs aren't cut mid-line
        tokenize: (src) => {
          const m = BLOCK_MATH.exec(src);
          return m && latexOf(m) ? { type: "blockMath", raw: m[0], latex: latexOf(m) } : undefined;
        },
      },
    }).configure({ katexOptions: { ...katexOptions, displayMode: true }, onClick: (node, pos) => edit(node, pos, false) }),
    Extension.create({
      name: "mnMathFromText",
      addProseMirrorPlugins: () => [new Plugin({
        appendTransaction(transactions, _old, state) {
          if (!transactions.some((t) => t.docChanged || t.selectionSet || t.getMeta("mnMath"))) return null;
          const { inlineMath, blockMath } = state.schema.nodes, head = state.selection.head, found = [];
          state.doc.descendants((node, pos, parent) => {
            if (parent?.type.name === "codeBlock" || !node.isText || node.marks.some((m) => m.type.name === "code")) return;
            for (const m of node.text.matchAll(INLINE_MATH)) {
              const from = pos + m.index, to = from + m[0].length, latex = latexOf(m);
              if (!latex || (head >= from && head <= to)) continue;  // still being typed or edited
              // "$$…$$" or "\[…\]" alone in a paragraph is display maths; anything else stays in the line.
              const alone = parent.type.name === "paragraph" && parent.childCount === 1 && node.text.trim() === m[0];
              found.push(alone && (m[2] != null || m[3] != null)
                ? { from: pos - 1, to: pos - 1 + parent.nodeSize, node: blockMath.create({ latex }) }
                : { from, to, node: inlineMath.create({ latex }) });
            }
          });
          if (!found.length) return null;
          const tr = state.tr;
          for (const f of found.reverse()) tr.replaceWith(f.from, f.to, f.node);
          return tr;
        },
      })],
    }),
  ];
}

const AT_QUERY = /(?:^|[\s(\[])@([a-z]*)$/i;
const DAY_NAMES = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/** The "@" menu, like Notion's: Today, Tomorrow, the next weekdays, or "Pick a date…"; typing filters it. */
function atMenu(pickDate) {
  const fmt = (d) => d.toLocaleDateString(undefined, { weekday: "short", day: "numeric", month: "short" });
  return suggestMenu({
    find: AT_QUERY,
    label: "Dates",
    choices: (query) => {
      const now = new Date(), q = query.toLowerCase();
      // Today, Tomorrow, then the next six days by name; a week out is "Next <today's weekday>".
      const days = [0, 1, 2, 3, 4, 5, 6, 7].map((i) => {
        const d = new Date(now.getFullYear(), now.getMonth(), now.getDate() + i);
        const name = DAY_NAMES[d.getDay()];
        return { label: i === 0 ? "Today" : i === 1 ? "Tomorrow" : i === 7 ? `Next ${name}` : name, hint: fmt(d), day: isoDay(d) };
      });
      return [...days, { label: "Pick a date…", hint: "", day: null }]
        .filter((o) => !q || o.label.toLowerCase().startsWith(q) || (o.day === null && "pick".startsWith(q)));
    },
    apply: (option, view, range) => {
      const tr = view.state.tr;
      if (option.day) tr.insertText(`@${option.day} `, range.from, range.to);
      else tr.delete(range.from, range.to);
      view.dispatch(tr);
      view.focus();
      if (!option.day) pickDate?.();
    },
  });
}

// "/" at the start of a line or after a space; the query may hold single spaces ("/break page").
const SLASH_QUERY = /(?:^|\s)\/((?:[a-z0-9]+ ?)*)$/i;

/** Notion's most used "/" blocks; `keys` are other words that find one. Each command replaces the typed "/query". */
const SLASH_COMMANDS = [
  ["Text", "", "paragraph plain", (c) => c.setParagraph()],
  ["Heading 1", "#", "h1 title", (c) => c.setHeading({ level: 1 })],
  ["Heading 2", "##", "h2 subtitle", (c) => c.setHeading({ level: 2 })],
  ["Heading 3", "###", "h3", (c) => c.setHeading({ level: 3 })],
  ["Bulleted list", "-", "bullet unordered ul", (c) => c.toggleBulletList()],
  ["Numbered list", "1.", "ordered ol number", (c) => c.toggleOrderedList()],
  ["To-do list", "[]", "todo checklist task checkbox", (c) => c.toggleTaskList()],
  ["Quote", ">", "blockquote", (c) => c.toggleBlockquote()],
  ["Code", "```", "codeblock snippet", (c) => c.toggleCodeBlock()],
  ["Break page", "---", "divider line hr separator page break", (c) => c.setHorizontalRule()],
  ["Table", "", "grid", (c) => c.insertTable({ rows: 3, cols: 3, withHeaderRow: true })],
  ["Date", "@", "day calendar due reminder", null],  // the calendar pop-up
].map(([label, hint, keys, run]) => ({ label, hint, words: [...label.toLowerCase().split(" "), ...keys.split(" ")], run }));

function slashMenu(editor, pickDate) {
  return suggestMenu({
    find: SLASH_QUERY,
    label: "Blocks",
    choices: (query) => {
      const q = query.trim().toLowerCase();
      return SLASH_COMMANDS.filter((o) => !q || o.label.toLowerCase().startsWith(q) || o.words.some((w) => w.startsWith(q)));
    },
    apply: (option, view, range) => {
      // "Intro /divider": the space before the "/" goes too, so no line ends in a stray space.
      const from = view.state.doc.textBetween(range.from - 1, range.from) === " " ? range.from - 1 : range.from;
      const chain = editor.chain().focus().deleteRange({ from, to: range.to });
      (option.run ? option.run(chain) : chain).run();
      if (!option.run) pickDate?.();
    },
  });
}

/**
 * A menu that follows the caret while the text before it matches `find` (group 1 is the query): arrows move,
 * Return/Tab picks, Esc dismisses it for that trigger. apply(option, view, {from, to}) replaces the trigger text.
 */
function suggestMenu({ find, label, choices, apply }) {
  let menuView;
  return new Plugin({
    view: (view) => (menuView = suggestMenuView(view, find, label, choices, apply)),
    props: { handleKeyDown: (view, event) => menuView?.key(event) ?? false },
  });
}

function suggestMenuView(view, find, label, choices, apply) {
  const menu = Object.assign(document.createElement("div"), { className: "mn-at-menu" });
  menu.setAttribute("role", "listbox");
  menu.setAttribute("aria-label", label);
  let options = [], active = 0, at = null, dismissed = null;

  const close = () => { menu.remove(); at = null; const root = view.dom.closest(".mn-editor"); if (root) root.style.minHeight = ""; };
  const choose = (option) => {
    if (at == null) return;
    const range = { from: at, to: view.state.selection.from };
    close();
    apply(option, view, range);
  };
  const render = () => {
    menu.replaceChildren(...options.map((o, i) => {
      const item = document.createElement("div");
      item.className = "mn-at-item" + (i === active ? " active" : "");
      item.setAttribute("role", "option");
      item.setAttribute("aria-selected", String(i === active));
      item.append(Object.assign(document.createElement("span"), { textContent: o.label }),
        Object.assign(document.createElement("span"), { className: "mn-at-hint", textContent: o.hint }));
      item.onmousedown = (e) => { e.preventDefault(); choose(o); };
      item.onmouseenter = () => { active = i; render(); };
      return item;
    }));
    menu.children[active]?.scrollIntoView?.({ block: "nearest" });
  };
  const update = () => {
    const { $from, empty } = view.state.selection;
    const inCode = $from.parent.type.name === "codeBlock" || $from.marks().some((m) => m.type.name === "code");
    const before = empty && !inCode ? $from.parent.textBetween(Math.max(0, $from.parentOffset - 30), $from.parentOffset, null, "￼") : "";
    const match = before.match(find);
    const start = match ? $from.pos - match[1].length - 1 : null;
    if (start == null || start === dismissed) return close();
    if (start !== at) active = 0;
    at = start;
    options = choices(match[1]);
    if (!options.length) return close();
    active = Math.min(active, options.length - 1);
    render();
    const body = view.dom.parentElement;
    if (!body) return;
    if (menu.parentElement !== body) body.append(menu);
    const coords = view.coordsAtPos(start), frame = body.getBoundingClientRect();
    menu.style.top = `${coords.bottom - frame.top + 4}px`;
    menu.style.left = `${Math.max(0, coords.left - frame.left)}px`;
    // An editor sized to its content (onHeight) grows so the menu isn't cut off below a short note.
    const root = view.dom.closest(".mn-editor");
    if (root) root.style.minHeight = `${menu.offsetTop + menu.offsetHeight + 8}px`;
  };

  return {
    update,
    destroy: close,
    key(event) {
      if (at == null) return false;
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        active = (active + (event.key === "ArrowDown" ? 1 : options.length - 1)) % options.length;
        render();
      } else if (event.key === "Enter" || event.key === "Tab") {
        choose(options[active]);
      } else if (event.key === "Escape") {
        dismissed = at;
        close();
      } else {
        return false;
      }
      return true;
    },
  };
}

const el = (tag, className, text) => Object.assign(document.createElement(tag), { className, textContent: text ?? "" });

/**
 * On highlighted text (one line): "Add page" makes a note titled with it and links the highlight to it; "Link to a
 * note…" searches the notes and links to the one picked. For questions that point to the answers found later.
 * onAddPage(text) => Promise<id>; onFindNotes(query) => Promise<[{id, title, preview}]>. Returns the two actions
 * for their shortcuts.
 */
function selectionMenu(editor, body, { onAddPage, onFindNotes, onLinkNote }) {
  const bar = el("div", "mn-bubble");
  bar.setAttribute("role", "toolbar");
  bar.setAttribute("aria-label", "Highlighted text");
  let range = null, results = [], active = 0, searchTimer;

  const hide = () => { bar.remove(); range = null; clearTimeout(searchTimer); };
  const link = (id) => editor.chain().focus().setTextSelection(range).setLink({ href: `note://${id}` }).run();
  const button = (label, svg, run) => {
    const b = el("button");
    b.type = "button";
    b.innerHTML = svg; // our own constant markup
    b.append(el("span", "", label));
    b.onmousedown = (e) => e.preventDefault(); // keep the highlight
    b.onclick = run;
    return b;
  };
  const fail = (message) => { bar.replaceChildren(el("span", "mn-bubble-error", message)); setTimeout(hide, 4000); };

  const addPage = async () => {
    if (!range || !onAddPage) return false;
    const text = editor.state.doc.textBetween(range.from, range.to, " ").trim();
    if (!text) return false;
    try {
      const id = await onAddPage(text);
      link(id);
      hide();
      onLinkNote?.(id); // the host shows the new page (the main window: in a side peek)
    } catch (err) {
      fail(`Couldn't add the page: ${err.message}`);
    }
    return true;
  };

  const input = el("input", "mn-bubble-search");
  input.type = "search";
  input.placeholder = "Link to a note…";
  input.setAttribute("aria-label", "Find a note to link to");
  const list = el("div", "mn-bubble-results");
  list.setAttribute("role", "listbox");
  const renderResults = () => {
    list.replaceChildren(...results.map((note, i) => {
      const item = el("div", "mn-at-item mn-bubble-result" + (i === active ? " active" : ""));
      item.setAttribute("role", "option");
      item.setAttribute("aria-selected", String(i === active));
      item.append(el("span", "", note.title), el("span", "mn-at-hint", note.preview));
      item.onmousedown = (e) => { e.preventDefault(); link(note.id); hide(); };
      return item;
    }));
    if (!results.length) list.append(el("div", "mn-bubble-empty", input.value ? "No notes match" : "No other notes yet"));
  };
  const search = () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(async () => {
      try { results = await onFindNotes(input.value.trim()); } catch (err) { results = []; }
      active = 0;
      renderResults();
    }, 80);
  };
  input.oninput = search;
  input.onkeydown = (e) => {
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      active = (active + (e.key === "ArrowDown" ? 1 : results.length - 1)) % Math.max(results.length, 1);
      renderResults();
    } else if (e.key === "Enter" && results[active]) {
      link(results[active].id);
      hide();
    } else if (e.key === "Escape") {
      hide();
      editor.commands.focus();
    } else {
      return;
    }
    e.preventDefault();
    e.stopPropagation();
  };
  const findNote = () => {
    if (!range || !onFindNotes) return false;
    input.value = "";
    results = [];
    bar.replaceChildren(input, list);
    input.focus();
    search();
    return true;
  };
  // Hide once focus has really left both the editor and the menu (checked after it lands; relatedTarget isn't always set).
  const hideIfAway = () => setTimeout(() => {
    const now = document.activeElement;
    if (!bar.contains(now) && !editor.view.dom.contains(now)) hide();
  });
  bar.addEventListener("focusout", hideIfAway);

  const place = () => {
    const sel = editor.state.selection;
    if (sel.empty || !(sel instanceof TextSelection) || sel.$from.parent !== sel.$to.parent || editor.isActive("codeBlock")) return hide();
    range = { from: sel.from, to: sel.to };
    bar.replaceChildren(...[onAddPage && button("Add page", PAGE_ICON, addPage),
      onFindNotes && button("Link to a note…", NOTE_LINK_ICON, findNote)].filter(Boolean));
    if (!bar.isConnected) body.append(bar);
    const start = editor.view.coordsAtPos(sel.from), end = editor.view.coordsAtPos(sel.to), frame = body.getBoundingClientRect();
    const above = start.top - frame.top - bar.offsetHeight - 6;
    bar.style.top = `${above >= 0 ? above : end.bottom - frame.top + 6}px`;
    bar.style.left = `${Math.max(0, Math.min(start.left - frame.left, body.clientWidth - bar.offsetWidth))}px`;
  };
  editor.on("selectionUpdate", place);
  editor.on("blur", hideIfAway);
  // From the keyboard: the shortcuts work on the current highlight even before the menu is placed.
  const withRange = (run) => () => { const sel = editor.state.selection; if (sel.empty) return false; range = { from: sel.from, to: sel.to }; if (!bar.isConnected) place(); return run(); };
  return { addPage: withRange(addPage), findNote: withRange(findNote) };
}

/** Hovering a link to a note shows a quick look at it (title and first lines), like VS Code's hover; a click opens it. */
function noteHover(view, root, body, onNotePreview) {
  const card = el("div", "mn-hover");
  card.setAttribute("role", "tooltip");
  let timer, current = null;
  const hide = () => { clearTimeout(timer); current = null; card.remove(); root.style.minHeight = ""; };
  view.dom.addEventListener("mouseover", (e) => {
    const a = e.target.closest?.('a[href^="note://"]');
    if (!a || a === current) return;
    hide();
    current = a;
    timer = setTimeout(async () => {
      let note;
      try { note = await onNotePreview(a.getAttribute("href").slice("note://".length)); }
      catch (err) { note = { title: "Can't show this note", preview: err.message }; }
      if (current !== a) return;
      card.replaceChildren(el("strong", "", note.title), el("p", "", note.preview || "No additional text"), el("small", "", "Click to open"));
      body.append(card);
      const rect = a.getBoundingClientRect(), frame = body.getBoundingClientRect();
      card.style.top = `${rect.bottom - frame.top + 4}px`;
      card.style.left = `${Math.max(0, Math.min(rect.left - frame.left, body.clientWidth - card.offsetWidth))}px`;
      root.style.minHeight = `${body.offsetTop + card.offsetTop + card.offsetHeight + 8}px`; // a short note's editor grows to fit it
    }, 350);
  });
  view.dom.addEventListener("mouseout", (e) => {
    const a = e.target.closest?.('a[href^="note://"]');
    if (a && !a.contains(e.relatedTarget)) hide();
  });
  view.dom.addEventListener("keydown", hide);
  view.dom.addEventListener("mousedown", hide);
}

let calendars = 0; // keeps day ids unique when one page has several editors (the browser panel)

/**
 * 📅 and "Pick a date…": a month calendar that pops up at the cursor. Arrows move a day or a week, PageUp/PageDown a
 * month, Return picks, Esc closes; the day goes in as "@yyyy-mm-dd ". Returns the function that opens it.
 */
function datePopover(editor, root, body) {
  const id = `mn-cal${++calendars}`;
  const pop = Object.assign(document.createElement("div"), { className: "mn-cal" });
  pop.setAttribute("role", "dialog");
  pop.setAttribute("aria-label", "Pick a date");
  const title = Object.assign(document.createElement("span"), { className: "mn-cal-title" });
  title.setAttribute("aria-live", "polite");
  const step = (label, text, months) => {
    const b = Object.assign(document.createElement("button"), { type: "button", textContent: text, title: label });
    b.setAttribute("aria-label", label);
    b.onmousedown = (e) => e.preventDefault(); // keep focus on the grid
    b.onclick = () => move(0, months);
    return b;
  };
  const head = Object.assign(document.createElement("div"), { className: "mn-cal-head" });
  head.append(step("Previous month", "‹", -1), title, step("Next month", "›", 1));
  const grid = Object.assign(document.createElement("div"), { className: "mn-cal-grid", tabIndex: 0 });
  grid.setAttribute("role", "grid");
  pop.append(head, grid);
  let day; // the highlighted day

  const close = (refocus) => { pop.remove(); root.style.minHeight = ""; if (refocus) editor.commands.focus(); };
  const pick = (d) => { close(false); editor.chain().focus().insertContent(`@${isoDay(d)} `).run(); };
  const move = (days, months = 0) => {
    const y = day.getFullYear(), m = day.getMonth() + months;
    day = new Date(y, m, Math.min(day.getDate(), new Date(y, m + 1, 0).getDate()) + days); // Jan 31 + 1 month = Feb 28
    render();
  };
  const cell = (role, text, label) => {
    const c = Object.assign(document.createElement("div"), { textContent: text });
    c.setAttribute("role", role);
    c.setAttribute("aria-label", label);
    return c;
  };
  const row = (cells) => {
    const r = Object.assign(document.createElement("div"), { className: "mn-cal-row" });
    r.setAttribute("role", "row");
    r.append(...cells);
    return r;
  };
  const render = () => {
    const today = isoDay(new Date()), chosen = isoDay(day);
    title.textContent = day.toLocaleDateString(undefined, { month: "long", year: "numeric" });
    // shortcut: weeks start on Sunday in every locale; read Intl.Locale weekInfo if someone asks for Monday.
    const start = new Date(day.getFullYear(), day.getMonth(), 1 - new Date(day.getFullYear(), day.getMonth(), 1).getDay());
    const at = (i) => new Date(start.getFullYear(), start.getMonth(), start.getDate() + i);
    const names = [0, 1, 2, 3, 4, 5, 6].map((i) => cell("columnheader",
      at(i).toLocaleDateString(undefined, { weekday: "narrow" }), at(i).toLocaleDateString(undefined, { weekday: "long" })));
    const weeks = [0, 1, 2, 3, 4, 5].map((w) => row([0, 1, 2, 3, 4, 5, 6].map((i) => {
      const d = at(w * 7 + i), iso = isoDay(d);
      const c = cell("gridcell", String(d.getDate()),
        d.toLocaleDateString(undefined, { weekday: "long", day: "numeric", month: "long", year: "numeric" }));
      c.id = `${id}-${iso}`;
      c.className = "mn-cal-day" + (d.getMonth() !== day.getMonth() ? " out" : "") + (iso === today ? " today" : "")
        + (iso === chosen ? " active" : "");
      c.setAttribute("aria-selected", String(iso === chosen));
      if (iso === today) c.setAttribute("aria-current", "date");
      c.onmousedown = (e) => e.preventDefault();
      c.onclick = () => pick(d);
      return c;
    })));
    grid.replaceChildren(row(names), ...weeks);
    grid.setAttribute("aria-activedescendant", `${id}-${chosen}`);
  };

  grid.onkeydown = (e) => {
    const days = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -7, ArrowDown: 7 }[e.key];
    if (days) move(days);
    else if (e.key === "PageUp" || e.key === "PageDown") move(0, e.key === "PageUp" ? -1 : 1);
    else if (e.key === "Enter" || e.key === " ") pick(day);
    else return;
    e.preventDefault();
    e.stopPropagation();
  };
  pop.onkeydown = (e) => {
    if (e.key !== "Escape") return;
    e.preventDefault();
    e.stopPropagation(); // Esc closes the calendar, not the panel around the editor
    close(true);
  };
  pop.addEventListener("focusout", (e) => { if (!pop.contains(e.relatedTarget)) close(false); });

  return () => {
    const now = new Date();
    day = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    render();
    body.append(pop);
    const coords = editor.view.coordsAtPos(editor.state.selection.from), frame = body.getBoundingClientRect();
    const h = pop.offsetHeight;
    // Below the line, or above it when the window ends first (a long note in the main window).
    const above = coords.bottom + h + 8 > window.innerHeight && coords.top - h - 4 >= 0;
    pop.style.top = `${above ? coords.top - frame.top - h - 4 : coords.bottom - frame.top + 4}px`;
    pop.style.left = `${Math.max(0, Math.min(coords.left - frame.left, body.clientWidth - pop.offsetWidth))}px`;
    // An editor sized to its content (onHeight) grows so the calendar isn't cut off below a short note.
    if (!above) root.style.minHeight = `${body.offsetTop + pop.offsetTop + h + 8}px`;
    grid.focus();
    return true;
  };
}

const PAGE_ICON = icon('<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6M12 12v6M9 15h6"/>');
const NOTE_LINK_ICON = icon('<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>');
const LINK_ICON = icon('<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>');

/**
 * Mounts a Markdown-backed rich editor into `element`.
 * onChange(markdown) fires on every user edit (never for setMarkdown); onLinkNote(id) fires for note://<id> links.
 * fontSize is in px; titleLine styles the first block as the note's title (Apple Notes); onHeight(px) reports the
 * content height so a host can size the editor to fit. onAI(action, markdown) => Promise<string> adds a ✨ menu of
 * Apple Intelligence edits (see AI_ACTIONS); the host runs the model, the editor applies the result as one undoable step.
 * datePattern ("dd/MM/yyyy", …) shows date chips that way; the Markdown keeps "@yyyy-mm-dd".
 * onAddPage / onFindNotes add "Add page" and "Link to a note…" on highlighted text (see selectionMenu); onNotePreview(id)
 * => Promise<{title, preview}> shows a card when hovering a note link.
 */
export function mount(element, { markdown = "", placeholder = "Write a note…", onChange, onLinkNote, toolbar = true,
  fontSize, titleLine = false, onHeight, onAI, onTag, onDate, datePattern, onAddPage, onFindNotes, onNotePreview } = {}) {
  const root = document.createElement("div");
  root.className = "mn-editor" + (titleLine ? " mn-title-line" : "");
  if (fontSize) root.style.setProperty("--mn-font-size", `${fontSize}px`);
  const bar = document.createElement("div");
  bar.className = "mn-toolbar";
  bar.setAttribute("role", "toolbar");
  bar.setAttribute("aria-label", "Formatting");
  bar.hidden = !toolbar;
  let pages; // "Add page" / "Link to a note…" on highlighted text, when the host supports them
  let pickDate; // set once the editor exists; the "@" menu's "Pick a date…" uses it
  const linkForm = document.createElement("form");
  linkForm.className = "mn-link";
  linkForm.hidden = true;
  const linkInput = document.createElement("input");
  linkInput.type = "url";
  linkInput.placeholder = "https://… or note://id — empty removes";
  linkInput.setAttribute("aria-label", "Link address");
  linkForm.append(linkInput);
  const body = document.createElement("div");
  body.className = "mn-body";
  root.append(bar, linkForm, body);
  element.append(root);

  const openLink = () => {
    linkInput.value = editor.getAttributes("link").href || "";
    linkForm.hidden = false;
    linkInput.focus();
    return true;
  };
  linkForm.onsubmit = (e) => {
    e.preventDefault();
    const href = linkInput.value.trim();
    const chain = editor.chain().focus().extendMarkRange("link");
    (href ? chain.setLink({ href }) : chain.unsetLink()).run();
    linkForm.hidden = true;
  };
  linkInput.onkeydown = (e) => {
    if (e.key !== "Escape") return;
    linkForm.hidden = true;
    editor.commands.focus();
  };

  // Shortcuts the kits don't ship with: ⌘⇧X strike (Apple Notes / Google Docs habit) and ⌘K link.
  const Extra = Extension.create({
    name: "mnShortcuts",
    priority: 1000, // ahead of HardBreak, so Shift-Enter inside code stays in the block
    addKeyboardShortcuts: () => ({
      "Shift-Enter": () => editor.isActive("codeBlock") && editor.commands.newlineInCode(),
      "Mod-Shift-x": () => editor.commands.toggleStrike(),
      "Mod-k": openLink,
      "Mod-Alt-p": () => pages?.addPage() ?? false,
      "Mod-Shift-k": () => pages?.findNote() ?? false,
      "Mod-Shift-ArrowUp": () => moveBlock(editor, -1),
      "Mod-Shift-ArrowDown": () => moveBlock(editor, 1),
    }),
  });

  const editor = new Editor({
    element: body,
    extensions: [
      tagHighlighter(onTag),
      dates(onDate, () => pickDate?.(), datePattern),
      ...maths(() => editor),
      Extension.create({ name: "mnSlash", addProseMirrorPlugins() { return [slashMenu(this.editor, () => pickDate?.())]; } }),
      dragHandle(),
      StarterKit.configure({ link: { openOnClick: false, protocols: ["note"], autolink: true },
        dropcursor: false }), // the drag handle draws its own line between blocks
      TaskList,
      TaskItem.configure({ nested: true }),
      TableKit.configure({ table: { resizable: false } }),
      Image,
      Placeholder.configure({ placeholder }),
      Markdown,
      Extra,
    ],
    content: markdown,
    contentType: "markdown",
    editorProps: {
      attributes: { class: "mn-content", role: "textbox", "aria-multiline": "true", "aria-label": placeholder },
      // Runs before the link plugin: note:// goes to the host, web links open in a new tab with ⌘-click.
      handleClick(view, pos, event) {
        const href = event.target.closest?.("a")?.getAttribute("href");
        if (!href) return false;
        if (href.startsWith("note://")) {
          onLinkNote?.(href.slice("note://".length));
          return true;
        }
        if (event.metaKey) {
          window.open(href, "_blank", "noopener");
          return true;
        }
        return false;
      },
    },
    onUpdate: () => onChange?.(editor.getMarkdown()),
  });

  editor.view.dispatch(editor.state.tr.setMeta("mnMath", true));  // maths saved as text before formulas rendered
  const buttons = TOOLBAR.map((item) => {
    if (!item) {
      bar.append(Object.assign(document.createElement("span"), { className: "mn-sep" }));
      return null;
    }
    const [label, name, run, active] = item;
    const b = document.createElement("button");
    b.type = "button";
    b.innerHTML = label; // our own constant markup
    b.title = name;
    b.setAttribute("aria-label", name);
    b.onmousedown = (e) => e.preventDefault(); // keep the editor's selection
    b.onclick = () => run(editor.chain().focus()).run();
    bar.append(b);
    return [b, active];
  }).filter(Boolean);
  // 📅: pick a day, insert "@yyyy-mm-dd" at the cursor; the calendar then shows this line on that day.
  const openDate = datePopover(editor, root, body);
  pickDate = openDate;
  const dateButton = Object.assign(document.createElement("button"), { type: "button", innerHTML: CALENDAR_ICON, title: "Add a date" });
  dateButton.setAttribute("aria-label", "Add a date");
  dateButton.onmousedown = (e) => e.preventDefault();
  dateButton.onclick = openDate;
  bar.append(dateButton);
  const linkButton = document.createElement("button");
  linkButton.type = "button";
  linkButton.innerHTML = LINK_ICON;
  linkButton.title = linkButton.ariaLabel = "Link";
  linkButton.onmousedown = (e) => e.preventDefault();
  linkButton.onclick = openLink;
  bar.append(linkButton);
  const refreshToolbar = () => {
    for (const [b, active] of buttons) {
      b.setAttribute("aria-pressed", String(Array.isArray(active) ? editor.isActive(...active) : editor.isActive(active)));
    }
  };
  editor.on("transaction", refreshToolbar);
  refreshToolbar();
  if (onAI) root.append(aiMenu(editor, onAI));
  if (onAddPage || onFindNotes) pages = selectionMenu(editor, body, { onAddPage, onFindNotes, onLinkNote });
  if (onNotePreview) noteHover(editor.view, root, body, onNotePreview);
  let observer;
  if (onHeight && typeof ResizeObserver !== "undefined") {
    observer = new ResizeObserver(() => onHeight(Math.ceil(root.getBoundingClientRect().height)));
    observer.observe(root);
  }

  return {
    editor,
    setMarkdown: (md) => editor.commands.setContent(md, { contentType: "markdown", emitUpdate: false }),
    getMarkdown: () => editor.getMarkdown(),
    focus: () => editor.commands.focus("end"),
    isFocused: () => editor.isFocused || root.contains(document.activeElement),
    setToolbar: (on) => { bar.hidden = !on; },
    destroy: () => { observer?.disconnect(); editor.destroy(); root.remove(); },
  };
}
