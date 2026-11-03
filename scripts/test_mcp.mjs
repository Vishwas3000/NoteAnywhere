// The MCP server end to end, as Claude, Codex or Gemini start it: the real binary with --mcp over stdio, both protocol
// eras, and every tool. Its store is a scratch folder, never your notes.
// Usage: node scripts/test_mcp.mjs [path to MemoryNotes]   (default: the installed app, else .build/release)
import fs from "fs"; import os from "os"; import path from "path"; import { spawn } from "child_process"; import readline from "readline";

const repo = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const bin = process.argv[2] ?? [path.join(os.homedir(), "Applications/NoteAnywhere.app/Contents/MacOS/MemoryNotes"),
  "/Applications/NoteAnywhere.app/Contents/MacOS/MemoryNotes", path.join(repo, ".build/release/MemoryNotes")].find(fs.existsSync);
if (!bin) { console.log("FAIL no MemoryNotes binary: run ./scripts/install.sh or swift build -c release"); process.exit(1); }
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "mn-mcp-"));
const server = spawn(bin, ["--mcp"], { env: { ...process.env, MEMORYNOTES_DIR: tmp }, stdio: ["pipe", "pipe", "inherit"] });
const replies = new Map();
readline.createInterface({ input: server.stdout }).on("line", (line) => {
  const msg = JSON.parse(line); // anything but JSON on stdout breaks every client
  replies.get(msg.id)?.(msg);
});
let next = 1;
const rpc = (method, params = {}) => new Promise((resolve, reject) => {
  const id = next++;
  const timer = setTimeout(() => reject(new Error(`${method}: no reply in 30 s`)), 30000);
  replies.set(id, (msg) => { clearTimeout(timer); resolve(msg); });
  server.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
});
const tool = async (name, args = {}) => {
  const r = await rpc("tools/call", { name, arguments: args });
  const text = r.result?.content?.[0]?.text;
  if (r.result?.isError) return { error: true, value: text }; // errors are a sentence for the model, not JSON
  return { error: false, value: JSON.parse(text ?? "null") };
};
let failed = 0;
const expect = (label, ok, detail) => {
  if (!ok) failed++;
  console.log(`${ok ? "PASS" : "FAIL"} ${label}${ok ? "" : `: ${JSON.stringify(detail)}`}`);
};

try {
  console.log(`server: ${bin}`);
  const init = await rpc("initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "1" } });
  expect("initialize (2025-06-18)", init.result?.protocolVersion === "2025-06-18" && init.result?.serverInfo?.name === "NoteAnywhere", init);
  server.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized" }) + "\n");
  const meta = { "io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {} };
  const discover = await rpc("server/discover", { _meta: meta });
  expect("server/discover (2026-07-28)", discover.result?.supportedVersions?.includes("2026-07-28") && discover.result?.resultType === "complete", discover);
  const list = await rpc("tools/list");
  const names = list.result?.tools?.map((t) => t.name) ?? [];
  expect("tools/list has all 11 tools", names.length === 11 && !names.some((n) => /delete/.test(n)), names);

  const made = await tool("create_note", { text: "Launch plan\n- [ ] Ship the build @2026-11-10\nDentist @2026-11-05{red} #demo", url: "example.com/launch" });
  const id = made.value?.id;
  expect("create_note", !made.error && made.value?.title === "Launch plan", made);
  const got = await tool("get_note", { id });
  expect("get_note: text, tags, dated lines", got.value?.text?.includes("@2026-11-05{red}") && got.value?.tags?.includes("demo")
    && got.value?.dates?.map((d) => d.day).join() === "2026-11-10,2026-11-05", got.value);
  const tasks = await tool("list_tasks", { from: "2026-11-01", to: "2026-11-30" });
  expect("list_tasks: both days, the colour tag not in the words", tasks.value?.total === 2
    && tasks.value.lines.some((l) => l.text === "Dentist #demo"), tasks.value);
  const found = await tool("search_notes", { query: "launch plan" });
  expect("search_notes", found.value?.[0]?.id === id, found.value);
  const byTag = await tool("list_notes", { tag: "#demo" });
  expect("list_notes by #tag", byTag.value?.total === 1, byTag.value);
  const tick = await tool("set_task_done", { id, line: 1, done: true });
  const appended = await tool("append_to_note", { id, text: "- [ ] Tell the team" });
  const after = await tool("get_note", { id });
  expect("set_task_done + append_to_note", !tick.error && !appended.error
    && after.value?.text === "Launch plan\n- [x] Ship the build @2026-11-10\nDentist @2026-11-05{red} #demo\n- [ ] Tell the team", after.value?.text);
  const stale = await tool("replace_note_text", { id, text: "gone", expected_updated_at: 1 });
  const replaced = await tool("replace_note_text", { id, text: "Launch plan v2", expected_updated_at: after.value?.updated_at });
  expect("replace_note_text refuses a stale read, takes a fresh one", stale.error && !replaced.error
    && (await tool("get_note", { id })).value?.text === "Launch plan v2", { stale, replaced });
  const colored = await tool("update_note", { id, pinned: true, color: "green" });
  const pinned = await tool("list_notes", { pinned: true });
  expect("update_note: pin and colour", !colored.error && pinned.value?.notes?.[0]?.id === id, { colored, pinned: pinned.value });
  const tags = await tool("list_tags"), folders = await tool("list_folders");
  expect("list_tags and list_folders answer", Array.isArray(tags.value) && Array.isArray(folders.value), { tags, folders });
  const missing = await tool("get_note", { id: "00000000-0000-0000-0000-000000000000" });
  const unknown = await rpc("tools/call", { name: "delete_note", arguments: { id } });
  expect("errors: a missing note, and no delete tool", missing.error && unknown.error?.code === -32602, { missing, unknown });
} catch (e) {
  failed++;
  console.log(`FAIL ${e.message}`);
} finally {
  server.stdin.end();
  fs.rmSync(tmp, { recursive: true, force: true });
}
console.log(failed ? `${failed} failed` : "mcp ok");
process.exit(failed ? 1 : 0);
