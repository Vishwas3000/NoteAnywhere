import { Editor, Extension, InputRule } from "@tiptap/core";
import { NodeSelection, Plugin, TextSelection } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import StarterKit from "@tiptap/starter-kit";
import { TaskItem, TaskList } from "@tiptap/extension-list";
import { TableKit } from "@tiptap/extension-table";
import Image from "@tiptap/extension-image";
import { Placeholder } from "@tiptap/extensions";
import { Markdown } from "@tiptap/markdown";
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

/** Date chips (⌘-click opens the day via onDate) and "@today " / "@fri " typed into real dates. */
function dates(onDate) {
  return Extension.create({
    name: "mnDates",
    addInputRules: () => [new InputRule({
      find: SHORTHAND,
      handler: ({ state, range, match }) => {
        const start = range.from + match[0].indexOf(match[1]);
        state.tr.insertText(`@${dayFor(match[2])} `, start, range.to);
      },
    })],
    addProseMirrorPlugins: () => [new Plugin({
      props: {
        decorations(state) {
          const found = [];
          state.doc.descendants((node, pos, parent) => {
            if (parent?.type.name === "codeBlock" || !node.isText || node.marks.some((m) => m.type.name === "code")) return;
            for (const m of node.text.matchAll(DATE)) {
              const day = new Date(`${m[3]}T00:00`);
              if (Number.isNaN(day.getTime()) || isoDay(day) !== m[3]) continue; // 2026-02-30 isn't a day
              const from = pos + m.index + m[1].length;
              found.push(Decoration.inline(from, from + m[2].length, {
                class: "mn-date", "data-day": m[3],
                title: day.toLocaleDateString(undefined, { weekday: "long", day: "numeric", month: "long" })
                  + (onDate ? " · ⌘-click to open this day" : ""),
              }));
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

const LINK_ICON = icon('<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>');

/**
 * Mounts a Markdown-backed rich editor into `element`.
 * onChange(markdown) fires on every user edit (never for setMarkdown); onLinkNote(id) fires for note://<id> links.
 * fontSize is in px; titleLine styles the first block as the note's title (Apple Notes); onHeight(px) reports the
 * content height so a host can size the editor to fit. onAI(action, markdown) => Promise<string> adds a ✨ menu of
 * Apple Intelligence edits (see AI_ACTIONS); the host runs the model, the editor applies the result as one undoable step.
 */
export function mount(element, { markdown = "", placeholder = "Write a note…", onChange, onLinkNote, toolbar = true,
  fontSize, titleLine = false, onHeight, onAI, onTag, onDate } = {}) {
  const root = document.createElement("div");
  root.className = "mn-editor" + (titleLine ? " mn-title-line" : "");
  if (fontSize) root.style.setProperty("--mn-font-size", `${fontSize}px`);
  const bar = document.createElement("div");
  bar.className = "mn-toolbar";
  bar.setAttribute("role", "toolbar");
  bar.setAttribute("aria-label", "Formatting");
  bar.hidden = !toolbar;
  const linkForm = document.createElement("form");
  linkForm.className = "mn-link";
  linkForm.hidden = true;
  const linkInput = document.createElement("input");
  linkInput.type = "url";
  linkInput.placeholder = "https://… or note://id — empty removes";
  linkInput.setAttribute("aria-label", "Link address");
  linkForm.append(linkInput);
  const dateForm = Object.assign(document.createElement("form"), { className: "mn-link mn-date-form", hidden: true });
  const dateInput = Object.assign(document.createElement("input"), { type: "date" });
  dateInput.setAttribute("aria-label", "Date for this line");
  dateForm.append(dateInput);
  const body = document.createElement("div");
  body.className = "mn-body";
  root.append(bar, linkForm, dateForm, body);
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
      "Mod-Shift-ArrowUp": () => moveBlock(editor, -1),
      "Mod-Shift-ArrowDown": () => moveBlock(editor, 1),
    }),
  });

  const editor = new Editor({
    element: body,
    extensions: [
      tagHighlighter(onTag),
      dates(onDate),
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
  const openDate = () => {
    dateInput.value = isoDay(new Date());
    dateForm.hidden = false;
    dateInput.focus();
    dateInput.showPicker?.();
    return true;
  };
  const insertDate = () => {
    if (dateInput.value) editor.chain().focus().insertContent(`@${dateInput.value} `).run();
    dateForm.hidden = true;
  };
  dateForm.onsubmit = (e) => { e.preventDefault(); insertDate(); };
  dateInput.onkeydown = (e) => { if (e.key === "Escape") { dateForm.hidden = true; editor.commands.focus(); } };
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
