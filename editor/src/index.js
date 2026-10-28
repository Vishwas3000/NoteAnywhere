import { Editor, Extension } from "@tiptap/core";
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
const LINK_ICON = icon('<path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/>');

/**
 * Mounts a Markdown-backed rich editor into `element`.
 * onChange(markdown) fires on every user edit (never for setMarkdown); onLinkNote(id) fires for note://<id> links.
 * fontSize is in px; titleLine styles the first block as the note's title (Apple Notes); onHeight(px) reports the
 * content height so a host can size the editor to fit.
 */
export function mount(element, { markdown = "", placeholder = "Write a note…", onChange, onLinkNote, toolbar = true,
  fontSize, titleLine = false, onHeight } = {}) {
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
    addKeyboardShortcuts: () => ({
      "Mod-Shift-x": () => editor.commands.toggleStrike(),
      "Mod-k": openLink,
    }),
  });

  const editor = new Editor({
    element: body,
    extensions: [
      StarterKit.configure({ link: { openOnClick: false, protocols: ["note"], autolink: true } }),
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
