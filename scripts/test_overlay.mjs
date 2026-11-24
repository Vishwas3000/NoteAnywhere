// Browser overlay in headless Chromium: the toolbar icon (⌥⇧N) shows it, × closes it, and the icon brings it back
// at full height (it used to come back 0 px tall). With a built host (swift build -c release), also images (D53): a
// note's image shows, a pasted screenshot is kept by the host, and a pasted link becomes a card (D59). Its store is a
// scratch folder, never your notes.
// Needs Playwright: npm i -g playwright && npx playwright install chromium
import { createRequire } from "module";
import fs from "fs"; import os from "os"; import path from "path"; import { execFileSync, spawn } from "child_process";
const require = createRequire(import.meta.url);
const { chromium } = require(path.join(execFileSync("npm", ["root", "-g"]).toString().trim(), "playwright"));

const repo = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const ext = path.join(repo, "extension"), bin = path.join(repo, ".build/release/MemoryNotes");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "mn-overlay-"));
const hosted = fs.existsSync(bin);
process.env.MEMORYNOTES_DIR = path.join(tmp, "store"); // Chromium passes its environment on to the host
const host = (msg) => {
  const body = Buffer.from(JSON.stringify(msg)), len = Buffer.alloc(4);
  len.writeUInt32LE(body.length);
  return JSON.parse(execFileSync(bin, ["chrome-extension://test/"], { input: Buffer.concat([len, body]) }).subarray(4));
};
const PNG = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAEUlEQVR42mP4z8DwHwyB+AMAYMQK9v1ByAoAAAAASUVORK5CYII="; // 2×1
if (hosted) {
  // Chromium launches a copy: a host inside ~/Documents waits on macOS's "access Documents?" prompt and never answers.
  const copy = path.join(tmp, "MemoryNotes");
  fs.copyFileSync(bin, copy);
  fs.chmodSync(copy, 0o755);
  // with Sparkle beside it: the binary finds the framework through @loader_path (D75)
  fs.cpSync(path.join(path.dirname(bin), "Sparkle.framework"), path.join(tmp, "Sparkle.framework"), { recursive: true, verbatimSymlinks: true });
  fs.mkdirSync(path.join(tmp, "profile/NativeMessagingHosts"), { recursive: true });
  fs.writeFileSync(path.join(tmp, "profile/NativeMessagingHosts/com.memorynotes.host.json"), JSON.stringify({
    name: "com.memorynotes.host", description: "test", path: copy, type: "stdio",
    allowed_origins: ["chrome-extension://fmjimldgmehkakonbffiaacmpijhajop/"] }));
  const { src } = host({ op: "addImage", mime: "image/png", data: PNG });
  host({ op: "save", note: { id: "eeeeeeee-0000-0000-0000-000000000001", kind: "url", target: "127.0.0.1:8767/notes.html", label: "Page",
    text: `Diagram\n\n![](${src})`, createdAt: 1, updatedAt: 1 } });
  host({ op: "save", note: { id: "eeeeeeee-0000-0000-0000-000000000002", kind: "url", target: "youtube.com/watch?v=abc",
    label: "Video", text: "About this video", createdAt: 1, updatedAt: 1 } });
} else console.log("skip: images (no .build/release/MemoryNotes)");
fs.mkdirSync(path.join(tmp, "site"));
for (const name of ["plain", "notes"]) fs.writeFileSync(path.join(tmp, `site/${name}.html`), "<!doctype html><title>Page</title><p>A page");
fs.writeFileSync(path.join(tmp, "site/linked.html"), '<!doctype html><head><meta property="og:title" content="Linked page">'
  + '<meta name="description" content="A page to preview"><meta property="og:image" content="/pic.png"><link rel="icon" href="/pic.png"></head>');
fs.writeFileSync(path.join(tmp, "site/pic.png"), Buffer.from(PNG, "base64"));
const server = spawn("python3", ["-m", "http.server", "8767", "--bind", "127.0.0.1", "-d", path.join(tmp, "site")], { stdio: "ignore" });
const ctx = await chromium.launchPersistentContext(path.join(tmp, "profile"), { channel: "chromium", headless: true,
  args: [`--disable-extensions-except=${ext}`, `--load-extension=${ext}`] });
let failed = 0;
try {
  const sw = ctx.serviceWorkers()[0] ?? await ctx.waitForEvent("serviceworker");
  const page = await ctx.newPage();
  await page.goto("http://127.0.0.1:8767/plain.html"); // no notes: the panel starts hidden
  await page.waitForTimeout(1500);
  // What chrome.action.onClicked does in background.js.
  const icon = () => sw.evaluate(async () => {
    const [tab] = await chrome.tabs.query({ active: true });
    await chrome.tabs.sendMessage(tab.id, { type: "toggle" });
  });
  const frame = () => page.evaluate(() => {
    const f = document.querySelector("iframe[title=NoteAnywhere]");
    return { shown: f.style.display !== "none", height: parseFloat(f.style.height) };
  });
  const expect = async (label, shown) => {
    await page.waitForTimeout(800);
    const f = await frame();
    const ok = f.shown === shown && (!shown || f.height > 40);
    if (!ok) failed++;
    console.log(`${ok ? "PASS" : "FAIL"} ${label}: ${JSON.stringify(f)}`);
  };
  await icon(); await expect("icon opens", true);
  await page.frames().find((f) => f.url().includes("overlay.html")).locator(".close").click();
  await expect("× closes", false);
  await icon(); await expect("icon reopens", true);
  await icon(); await expect("icon hides", false);
  await icon(); await expect("icon shows again", true);

  // Dragging the header moves the panel, it stays on screen, and the next page opens it in the same spot.
  const spot = () => page.evaluate(() => {
    const r = document.querySelector("iframe[title=NoteAnywhere]").getBoundingClientRect();
    return { top: Math.round(r.top), right: Math.round(innerWidth - r.right) };
  });
  const before = await spot();
  const at = { x: page.viewportSize().width - before.right - 200, y: before.top + 20 }; // the header's title, not a button
  await page.mouse.move(at.x, at.y); await page.mouse.down();
  await page.mouse.move(at.x - 150, at.y + 100, { steps: 8 }); await page.mouse.up();
  await page.waitForTimeout(400);
  const after = await spot();
  const dragged = after.top === before.top + 100 && after.right === before.right + 150;
  console.log(`${dragged ? "PASS" : "FAIL"} drag moves the panel: ${JSON.stringify(before)} → ${JSON.stringify(after)}`);
  await page.mouse.move(at.x - 150, at.y + 100); await page.mouse.down();
  await page.mouse.move(page.viewportSize().width - 2, 2, { steps: 8 }); await page.mouse.up(); // far past the top-right corner
  await page.waitForTimeout(400);
  const edge = await spot();
  const kept = edge.top === 0 && edge.right === 0;
  console.log(`${kept ? "PASS" : "FAIL"} a drag past the edge stops at it: ${JSON.stringify(edge)}`);
  await page.mouse.move(at.x + 150, 10); await page.mouse.down();  // put it back somewhere distinct
  await page.mouse.move(at.x - 50, 90, { steps: 8 }); await page.mouse.up();
  await page.waitForTimeout(400);
  const placed = await spot();
  await page.reload(); await page.waitForTimeout(1500); await icon(); await page.waitForTimeout(800);
  const again = await spot();
  const remembered = again.top === placed.top && again.right === placed.right;
  console.log(`${remembered ? "PASS" : "FAIL"} the spot is remembered: ${JSON.stringify(placed)} → ${JSON.stringify(again)}`);
  failed += !dragged + !kept + !remembered;

  // The bottom-left grip resizes it (top-right corner stays), the frame follows, and the size is remembered.
  const box = () => page.evaluate(() => {
    const r = document.querySelector("iframe[title=NoteAnywhere]").getBoundingClientRect();
    return { left: Math.round(r.left), right: Math.round(r.right), top: Math.round(r.top), w: Math.round(r.width), h: Math.round(r.height) };
  });
  const b0 = await box();
  await page.mouse.move(b0.left + 5, b0.top + b0.h - 5); await page.mouse.down();
  await page.mouse.move(b0.left - 95, b0.top + b0.h + 75, { steps: 8 }); await page.mouse.up();
  await page.waitForTimeout(600);
  const b1 = await box();
  const resized = b1.w === b0.w + 100 && b1.h === b0.h + 80 && b1.right === b0.right && b1.top === b0.top;
  console.log(`${resized ? "PASS" : "FAIL"} the corner grip resizes the panel: ${JSON.stringify(b0)} → ${JSON.stringify(b1)}`);
  await page.reload(); await page.waitForTimeout(1500); await icon(); await page.waitForTimeout(800);
  const b2 = await box();
  const sizeKept = b2.w === b1.w && b2.h === b1.h;
  console.log(`${sizeKept ? "PASS" : "FAIL"} the size is remembered: ${JSON.stringify(b2)}`);
  failed += !resized + !sizeKept;

  if (hosted) {
    await page.goto("http://127.0.0.1:8767/notes.html"); // has a note: the panel shows by itself
    await page.waitForTimeout(1500);
    const overlay = page.frames().find((f) => f.url().includes("overlay.html"));
    const img = overlay.locator(".ProseMirror img").first();
    await img.waitFor({ timeout: 5000 });
    await page.waitForTimeout(500);
    const shown = await img.evaluate((i) => ({ blob: i.src.startsWith("blob:"), width: i.naturalWidth }));
    const ok = shown.blob && shown.width === 2;
    if (!ok) failed++;
    console.log(`${ok ? "PASS" : "FAIL"} a note's image shows: ${JSON.stringify(shown)}`);
    // Paste a screenshot (only the PNG on the clipboard) at the end of the note.
    await overlay.locator(".ProseMirror").first().click();
    await overlay.evaluate((png) => {
      const dt = new DataTransfer();
      dt.items.add(new File([Uint8Array.from(atob(png), (c) => c.charCodeAt(0))], "image.png", { type: "image/png" }));
      document.querySelector(".ProseMirror").dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
    }, PNG);
    await page.waitForTimeout(1500); // the save is debounced
    const text = host({ op: "list", url: "127.0.0.1:8767/notes.html" }).notes[0].text;
    const refs = text.match(/noteimage:[0-9a-f-]+/g) ?? [];
    const pasted = refs.length === 2 && refs[0] !== refs[1] && host({ op: "image", id: refs[1].slice(10) }).size === Buffer.from(PNG, "base64").length;
    if (!pasted) failed++;
    console.log(`${pasted ? "PASS" : "FAIL"} a pasted screenshot is kept: ${JSON.stringify(text)}`);
    // Paste a link and pick Card (D59): the Mac app fetches the page and keeps its picture; the card shows it.
    await overlay.evaluate(() => {
      const dt = new DataTransfer();
      dt.setData("text/plain", "http://127.0.0.1:8767/linked.html");
      document.querySelector(".ProseMirror").dispatchEvent(new ClipboardEvent("paste", { clipboardData: dt, bubbles: true, cancelable: true }));
    });
    const menu = await overlay.locator(".mn-at-item").allTextContents();
    for (const key of ["ArrowDown", "ArrowDown", "Enter"]) await page.keyboard.press(key);
    await overlay.locator(".mn-card img.mn-card-image").first().waitFor({ timeout: 10000 }).catch(() => {});
    await page.waitForTimeout(1500); // the save is debounced
    const saved = host({ op: "list", url: "127.0.0.1:8767/notes.html" }).notes[0].text;
    const picture = await overlay.locator(".mn-card img.mn-card-image").first().evaluate((i) => i.naturalWidth).catch(() => 0);
    const carded = menu.length === 3 && saved.includes("> [!bookmark] [Linked page](http://127.0.0.1:8767/linked.html)\n> A page to preview\n> ![](noteimage:")
      && picture === 2;
    if (!carded) failed++;
    console.log(`${carded ? "PASS" : "FAIL"} a pasted link becomes a card: ${JSON.stringify({ menu, picture, saved })}`);
    // Typing "@" at the end of a long line: the date menu stays inside the panel and nothing scrolls sideways.
    await overlay.locator(".ProseMirror p").first().click(); // "Diagram", not the card below it
    await page.keyboard.press("End");
    await page.keyboard.press("Enter");
    await page.keyboard.type("A line long enough to reach the panel's right edge @");
    await page.waitForTimeout(300);
    const at = await overlay.evaluate(() => {
      const menu = document.querySelector(".mn-at-menu"), r = menu?.getBoundingClientRect();
      const shifted = [...document.querySelectorAll("*")].filter((e) => e.scrollLeft > 0).map((e) => e.className || e.tagName);
      return { menu: !!menu, right: r && Math.round(r.right), width: document.documentElement.clientWidth, shifted };
    });
    const inside = at.menu && at.right <= at.width && at.shifted.length === 0;
    if (!inside) failed++;
    console.log(`${inside ? "PASS" : "FAIL"} "@" near the right edge: the menu fits and nothing scrolls sideways: ${JSON.stringify(at)}`);
    await page.keyboard.press("Escape");

    // ⌘F in the panel finds in its note, not in the page: every match marked, Return steps on, Esc closes the bar.
    const pageScroll = await page.evaluate(() => scrollY);
    await page.keyboard.press(process.platform === "darwin" ? "Meta+f" : "Control+f");
    await page.keyboard.type("e");
    const firstCount = await overlay.locator(".mn-find-count").textContent();
    await page.keyboard.press("Enter");
    const found = await overlay.evaluate(() => ({ count: document.querySelector(".mn-find-count").textContent,
      marks: document.querySelectorAll(".mn-find-match").length, current: document.querySelectorAll(".mn-find-current").length,
      focus: document.activeElement?.getAttribute("aria-label") }));
    await page.keyboard.press("Escape");
    const closed = await overlay.evaluate(() => document.querySelector(".mn-find").hidden && !document.querySelector(".mn-find-match"));
    const finds = /^1 of \d+$/.test(firstCount) && found.count.startsWith("2 of ") && found.marks > 1 && found.current === 1
      && found.focus === "Find in note" && closed && await page.evaluate(() => scrollY) === pageScroll;
    if (!finds) failed++;
    console.log(`${finds ? "PASS" : "FAIL"} ⌘F finds in the note: ${JSON.stringify({ firstCount, ...found, closed })}`);

    // The query names a YouTube video (D70): its note shows on that video only, whatever else the address carries.
    await ctx.route("https://www.youtube.com/**", (r) => r.fulfill({ contentType: "text/html", body: "<!doctype html><title>Video</title><p>A video" }));
    await page.goto("https://www.youtube.com/watch?v=abc&t=42s");
    await page.waitForTimeout(1500);
    await expect("a YouTube video's note shows on that video", true);
    await page.goto("https://www.youtube.com/watch?v=xyz");
    await page.waitForTimeout(1500);
    await expect("and not on another video", false);

    // Settings ▸ "Open notes by themselves" off (D63): a page with notes stays closed until the icon. The test host is a
    // bare binary named MemoryNotes, so its defaults domain is "MemoryNotes", not the app's.
    execFileSync("defaults", ["write", "MemoryNotes", "openNotesByThemselves", "-bool", "false"]);
    try {
      await page.goto("http://127.0.0.1:8767/notes.html");
      await page.waitForTimeout(1500);
      await expect("off: a page with notes stays closed", false);
      await icon(); await expect("off: the icon still opens it", true);
    } finally {
      execFileSync("defaults", ["delete", "MemoryNotes", "openNotesByThemselves"]);
    }
  }
} finally {
  server.kill();
  await ctx.close();
  fs.rmSync(tmp, { recursive: true, force: true });
}
console.log(failed ? `${failed} failed` : "overlay ok");
process.exit(failed ? 1 : 0);
