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

const TOOLBAR = [
  ["B", "Bold", (c) => c.toggleBold(), "bold"],
  ["I", "Italic", (c) => c.toggleItalic(), "italic"],
  ["S", "Strikethrough", (c) => c.toggleStrike(), "strike"],
  ["</>", "Inline code", (c) => c.toggleCode(), "code"],
  ["H1", "Heading 1", (c) => c.toggleHeading({ level: 1 }), ["heading", { level: 1 }]],
  ["H2", "Heading 2", (c) => c.toggleHeading({ level: 2 }), ["heading", { level: 2 }]],
  ["•", "Bullet list", (c) => c.toggleBulletList(), "bulletList"],
  ["1.", "Numbered list", (c) => c.toggleOrderedList(), "orderedList"],
  ["☐", "Checklist", (c) => c.toggleTaskList(), "taskList"],
  ["❝", "Quote", (c) => c.toggleBlockquote(), "blockquote"],
  ["⊞", "Insert table", (c) => c.insertTable({ rows: 3, cols: 3, withHeaderRow: true }), "table"],
];

/**
 * Mounts a Markdown-backed rich editor into `element`.
 * onChange(markdown) fires on every user edit (never for setMarkdown); onLinkNote(id) fires for note://<id> links.
 */
export function mount(element, { markdown = "", placeholder = "Write a note…", onChange, onLinkNote, toolbar = true } = {}) {
  const root = document.createElement("div");
  root.className = "mn-editor";
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

  const buttons = TOOLBAR.map(([label, name, run, active]) => {
    const b = document.createElement("button");
    b.type = "button";
    b.textContent = label;
    b.title = name;
    b.setAttribute("aria-label", name);
    b.onmousedown = (e) => e.preventDefault(); // keep the editor's selection
    b.onclick = () => run(editor.chain().focus()).run();
    bar.append(b);
    return [b, active];
  });
  const linkButton = document.createElement("button");
  linkButton.type = "button";
  linkButton.textContent = "🔗";
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

  return {
    editor,
    setMarkdown: (md) => editor.commands.setContent(md, { contentType: "markdown", emitUpdate: false }),
    getMarkdown: () => editor.getMarkdown(),
    focus: () => editor.commands.focus("end"),
    isFocused: () => editor.isFocused || root.contains(document.activeElement),
    setToolbar: (on) => { bar.hidden = !on; },
    destroy: () => { editor.destroy(); root.remove(); },
  };
}
