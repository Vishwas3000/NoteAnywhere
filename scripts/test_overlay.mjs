// Browser overlay in headless Chromium: the toolbar icon (⌥⇧N) shows it, × closes it, and the icon brings it back
// at full height (it used to come back 0 px tall). With a built host (swift build -c release), also images (D53): a
// note's image shows, and a pasted screenshot is kept by the host. Its store is a scratch folder, never your notes.
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
  fs.mkdirSync(path.join(tmp, "profile/NativeMessagingHosts"), { recursive: true });
  fs.writeFileSync(path.join(tmp, "profile/NativeMessagingHosts/com.memorynotes.host.json"), JSON.stringify({
    name: "com.memorynotes.host", description: "test", path: copy, type: "stdio",
    allowed_origins: ["chrome-extension://fmjimldgmehkakonbffiaacmpijhajop/"] }));
  const { src } = host({ op: "addImage", mime: "image/png", data: PNG });
  host({ op: "save", note: { id: "eeeeeeee-0000-0000-0000-000000000001", kind: "url", target: "127.0.0.1:8767/notes.html", label: "Page",
    text: `Diagram\n\n![](${src})`, createdAt: 1, updatedAt: 1 } });
} else console.log("skip: images (no .build/release/MemoryNotes)");
fs.mkdirSync(path.join(tmp, "site"));
for (const name of ["plain", "notes"]) fs.writeFileSync(path.join(tmp, `site/${name}.html`), "<!doctype html><title>Page</title><p>A page");
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
  }
} finally {
  server.kill();
  await ctx.close();
  fs.rmSync(tmp, { recursive: true, force: true });
}
console.log(failed ? `${failed} failed` : "overlay ok");
process.exit(failed ? 1 : 0);
