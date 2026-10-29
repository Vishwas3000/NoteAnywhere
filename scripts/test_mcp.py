"""End-to-end check of the MCP server (`MemoryNotes --mcp`) over stdio, against a temp store."""
import json, os, sqlite3, subprocess, sys, tempfile

BIN = sys.argv[1] if len(sys.argv) > 1 else ".build/release/MemoryNotes"
env = {**os.environ, "MEMORYNOTES_DIR": tempfile.mkdtemp()}
DB = os.path.join(env["MEMORYNOTES_DIR"], "memorynotes.sqlite")
# Word search needs the search model; borrow the installed app's copy (model files only) instead of downloading it.
models = os.path.expanduser("~/Library/Application Support/MemoryNotes/models")
if os.path.isdir(models):
    os.symlink(models, os.path.join(env["MEMORYNOTES_DIR"], "models"))

server = subprocess.Popen([BIN, "--mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env, text=True)
seq = 0

def send(msg):
    server.stdin.write(json.dumps(msg) + "\n")
    server.stdin.flush()

def rpc(method, params=None, modern=False):
    global seq
    seq += 1
    params = dict(params or {})
    if modern:
        params["_meta"] = {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
                           "io.modelcontextprotocol/clientCapabilities": {}}
    send({"jsonrpc": "2.0", "id": seq, "method": method, "params": params})
    reply = json.loads(server.stdout.readline())  # every stdout line must be one JSON-RPC message
    assert reply["id"] == seq, reply
    return reply

def tool(name, **args):
    result = rpc("tools/call", {"name": name, "arguments": args})["result"]
    text = result["content"][0]["text"]
    return (text, True) if result["isError"] else (json.loads(text), False)

def ok(name, **args):
    value, failed = tool(name, **args)
    assert not failed, (name, value)
    return value

def refused(name, **args):
    value, failed = tool(name, **args)
    assert failed, (name, value)
    return value

# Legacy handshake: the server echoes a version it knows, else offers its newest legacy one.
r = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}})["result"]
assert r["protocolVersion"] == "2025-06-18" and "tools" in r["capabilities"] and r["serverInfo"]["name"] == "NoteAnywhere"
assert rpc("initialize", {"protocolVersion": "2099-01-01"})["result"]["protocolVersion"] == "2025-11-25"
send({"jsonrpc": "2.0", "method": "notifications/initialized"})  # no reply expected
assert rpc("ping")["result"] == {}

# Modern (2026-07-28): per-request _meta, resultType on every result, version errors.
d = rpc("server/discover", modern=True)["result"]
assert d["supportedVersions"] == ["2026-07-28"] and d["resultType"] == "complete" and "tools" in d["capabilities"]
bad = rpc("tools/list", {"_meta": {"io.modelcontextprotocol/protocolVersion": "1900-01-01", "io.modelcontextprotocol/clientCapabilities": {}}})
assert bad["error"]["code"] == -32022 and "2026-07-28" in bad["error"]["data"]["supported"]
assert rpc("tools/list", {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}})["error"]["code"] == -32602
assert rpc("server/discover")["error"]["code"] == -32602
listed = rpc("tools/list", modern=True)["result"]
assert listed["resultType"] == "complete"
names = [t["name"] for t in listed["tools"]]
assert names == ["search_notes", "list_notes", "get_note", "list_tasks", "list_tags", "list_folders", "create_note",
                 "append_to_note", "replace_note_text", "update_note", "set_task_done"], names
assert "delete" not in " ".join(names)
assert rpc("tools/call", {"name": "delete_note", "arguments": {}})["error"]["code"] == -32602
assert rpc("nope")["error"]["code"] == -32601
server.stdin.write("{not json\n")
server.stdin.flush()
assert json.loads(server.stdout.readline())["error"]["code"] == -32700

# Create, append, read.
plan = ok("create_note", text="Launch plan\n- [ ] Call the printer @2026-10-30 #launch")["id"]
ok("append_to_note", id=plan, text="- [ ] Book the venue @2026-11-02")
note = ok("get_note", id=plan)
assert note["text"] == "Launch plan\n- [ ] Call the printer @2026-10-30 #launch\n- [ ] Book the venue @2026-11-02", note
assert note["title"] == "Launch plan" and note["kind"] == "plain" and note["tags"] == ["launch"]
assert [x["day"] for x in note["dates"]] == ["2026-10-30", "2026-11-02"]

page = ok("create_note", text="Read the caching docs", url="https://www.github.com/vercel/next.js/?tab=readme#top")["id"]
web = ok("get_note", id=page)
assert web["kind"] == "website" and web["target"] == "github.com/vercel/next.js" and web["source"] == "github.com"
refused("create_note", text="x", url="ftp://nope")
refused("create_note", text="x", folder="Nowhere")
refused("get_note", id="aaaaaaaa-0000-0000-0000-000000000000")

# Tasks: by day range, tick one, done ones drop out unless asked for.
tasks = ok("list_tasks", **{"from": "2026-10-01", "to": "2026-10-31"})
assert [(t["note_id"], t["line"], t["done"]) for t in tasks["lines"]] == [(plan, 1, False)], tasks
ok("set_task_done", id=plan, line=1, done=True)
assert ok("list_tasks")["total"] == 1
assert [t["done"] for t in ok("list_tasks", include_done=True)["lines"]] == [True, False]
refused("set_task_done", id=plan, line=0, done=True)  # the title isn't a checklist item
refused("list_tasks", **{"from": "30/10/2026"})

# Search: "#tag" needs no model; words do (skipped when no model is installed).
assert [h["id"] for h in ok("search_notes", query="#launch")] == [plan]
if os.path.isdir(models):
    hits = ok("search_notes", query="printer")
    assert hits[0]["id"] == plan and "printer" in hits[0]["snippet"], hits
else:
    print("skip: word search (no search model installed)")

# Replace refuses a stale updated_at, then works with the current one.
note = ok("get_note", id=plan)
refused("replace_note_text", id=plan, text="clobbered", expected_updated_at=note["updated_at"] - 1)
# A stale stamp sent as a string or a float is still checked, and junk is refused rather than ignored.
refused("replace_note_text", id=plan, text="clobbered", expected_updated_at=str(note["updated_at"] - 1))
refused("replace_note_text", id=plan, text="clobbered", expected_updated_at=float(note["updated_at"] - 1))
refused("replace_note_text", id=plan, text="clobbered", expected_updated_at="yesterday")
assert ok("get_note", id=plan)["text"] == note["text"]
ok("replace_note_text", id=plan, text="Launch plan v2", expected_updated_at=note["updated_at"])
assert ok("get_note", id=plan)["text"] == "Launch plan v2"

# Pins, colours, folders, tags.
with sqlite3.connect(DB) as db:
    db.execute("INSERT INTO folders (id, name, updated_at) VALUES ('cccccccc-0000-0000-0000-000000000001', 'Work', 1)")
updated = ok("update_note", id=page, pinned=True, color="blue", folder="work")
assert updated["pinned"] and updated["color"] == "blue" and updated["folder"] == "Work", updated
refused("update_note", id=page, color="magenta")
refused("update_note", id=page)
assert [n["id"] for n in ok("list_notes", folder="Work")["notes"]] == [page]
assert [n["id"] for n in ok("list_notes", source="github")["notes"]] == [page]
assert ok("list_folders") == [{"id": "cccccccc-0000-0000-0000-000000000001", "name": "Work", "notes": 1}]
ok("create_note", text="Ideas #launch #ml")
assert ok("list_tags") == [{"tag": "launch", "count": 1}, {"tag": "ml", "count": 1}]  # the plan lost its tag in v2
refused("list_notes", updated_since="last week")
assert ok("list_notes", updated_since="2000-01-01")["total"] == 3

# Locked notes: listed, never read or written; pin still works, like in the app.
locked = "dddddddd-0000-0000-0000-000000000001"
with sqlite3.connect(DB) as db:
    db.execute("INSERT INTO notes (id, kind, target, title, body_md, created_at, updated_at, locked) "
               "VALUES (?, 'url', '', '', 'mnlock:v1:c2VjcmV0', 1, 1, 1)", (locked,))
secret = ok("get_note", id=locked)
assert secret["locked"] and secret["title"] == "Locked Note" and "text" not in secret and "dates" not in secret, secret
refused("append_to_note", id=locked, text="x")
refused("replace_note_text", id=locked, text="x")
assert ok("update_note", id=locked, pinned=True)["pinned"]
with sqlite3.connect(DB) as db:
    assert db.execute("SELECT body_md FROM notes WHERE id = ?", (locked,)).fetchone() == ("mnlock:v1:c2VjcmV0",)
assert all("Locked" not in h["title"] for h in ok("search_notes", query="#launch"))

# Writes go through the app's save path: a day snapshot and the sync flag.
with sqlite3.connect(DB) as db:
    assert db.execute("SELECT dirty FROM notes WHERE id = ?", (plan,)).fetchone() == (1,)
    assert db.execute("SELECT count(*) FROM snapshots WHERE note_id = ?", (plan,)).fetchone()[0] >= 1

# Closing stdin ends the server.
server.stdin.close()
assert server.wait(timeout=10) == 0
print("mcp ok")
