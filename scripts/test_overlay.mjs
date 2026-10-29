// Browser overlay in headless Chromium: the toolbar icon (⌥⇧N) shows it, × closes it, and the icon brings it back
// at full height (it used to come back 0 px tall). Needs Playwright: npm i -g playwright && npx playwright install chromium
import { createRequire } from "module";
import fs from "fs"; import os from "os"; import path from "path"; import { execFileSync, spawn } from "child_process";
const require = createRequire(import.meta.url);
const { chromium } = require(path.join(execFileSync("npm", ["root", "-g"]).toString().trim(), "playwright"));

const ext = path.resolve(path.dirname(new URL(import.meta.url).pathname), "../extension");
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "mn-overlay-"));
fs.mkdirSync(path.join(tmp, "site"));
fs.writeFileSync(path.join(tmp, "site/index.html"), "<!doctype html><title>Page</title><p>A page");
const server = spawn("python3", ["-m", "http.server", "8767", "--bind", "127.0.0.1", "-d", path.join(tmp, "site")], { stdio: "ignore" });
const ctx = await chromium.launchPersistentContext(path.join(tmp, "profile"), { channel: "chromium", headless: true,
  args: [`--disable-extensions-except=${ext}`, `--load-extension=${ext}`] });
let failed = 0;
try {
  const sw = ctx.serviceWorkers()[0] ?? await ctx.waitForEvent("serviceworker");
  const page = await ctx.newPage();
  await page.goto("http://127.0.0.1:8767/");
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
} finally {
  server.kill();
  await ctx.close();
  fs.rmSync(tmp, { recursive: true, force: true });
}
console.log(failed ? `${failed} failed` : "overlay ok");
process.exit(failed ? 1 : 0);
