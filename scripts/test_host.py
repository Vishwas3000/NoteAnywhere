"""End-to-end check of the native messaging host: frames JSON like Chrome does, against a temp store."""
import datetime, json, os, sqlite3, struct, subprocess, sys, tempfile

BIN = sys.argv[1] if len(sys.argv) > 1 else ".build/release/MemoryNotes"
env = {**os.environ, "MEMORYNOTES_DIR": tempfile.mkdtemp()}
DB = os.path.join(env["MEMORYNOTES_DIR"], "memorynotes.sqlite")

def call(msg, env=env):
    body = json.dumps(msg).encode()
    out = subprocess.run([BIN, "chrome-extension://test/"], input=struct.pack("<I", len(body)) + body,
                         capture_output=True, env=env, timeout=10).stdout
    (n,) = struct.unpack("<I", out[:4])
    assert len(out) == 4 + n, out
    return json.loads(out[4:])

def note(id, target, t=1, kind="url"):
    return {"id": id, "kind": kind, "target": target, "label": target, "text": "hi " + target, "createdAt": t, "updatedAt": t}

site = "aaaaaaaa-0000-0000-0000-000000000001"
page = "aaaaaaaa-0000-0000-0000-000000000002"
assert call({"op": "save", "note": note(site, "github.com", 1)})["ok"]
assert call({"op": "save", "note": note(page, "github.com/vercel/next.js", 2)})["ok"]

# A page shows its own notes and the notes of pages under it, never its parents'.
ids = lambda url: [n["id"] for n in call({"op": "list", "url": url})["notes"]]
assert ids("github.com/") == [site, page]
assert ids("github.com/vercel") == [page]
assert ids("github.com/vercel/next.js") == [page]
assert ids("github.com/vercel/next.js/") == [page]
assert ids("github.com/vercel/next.jsx") == []
assert ids("github.company.com/") == []

assert not call({"op": "save", "note": note("../../evil", "x.com")})["ok"], "non-UUID ids must be rejected"
assert not call({"op": "save", "note": note(site, "x.com", kind="app")})["ok"], "browser can't write app notes"
assert not call({"op": "nope"})["ok"]

# The browser can't take over an app note by reusing its id.
app = "bbbbbbbb-0000-0000-0000-000000000001"
with sqlite3.connect(DB) as db:
    db.execute("INSERT INTO notes (id, kind, target, title, body_md, created_at, updated_at) VALUES (?, 'app', 'com.apple.finder', 'Finder', 'mine', 1, 1)", (app,))
assert call({"op": "save", "note": note(app, "evil.com")})["ok"]
with sqlite3.connect(DB) as db:
    assert db.execute("SELECT kind, body_md FROM notes WHERE id = ?", (app,)).fetchone() == ("app", "mine")

# Every save also writes that day's snapshot for the calendar.
today = datetime.date.today().isoformat()  # the host stamps updatedAt with "now"
with sqlite3.connect(DB) as db:
    assert db.execute("SELECT count(*) FROM snapshots WHERE note_id = ? AND day = ?", (page, today)).fetchone() == (1,)

# Delete is a tombstone: hidden from lists, row kept for sync, and a late save from an open tab can't revive it.
assert call({"op": "delete", "id": page})["ok"]
assert ids("github.com/") == [site]
assert call({"op": "save", "note": note(page, "github.com/vercel/next.js", 3)})["ok"]
assert ids("github.com/") == [site]
with sqlite3.connect(DB) as db:
    assert db.execute("SELECT deleted_at IS NOT NULL FROM notes WHERE id = ?", (page,)).fetchone() == (1,)

# One-time import of the old JSON layout: notes, history and vectors move in; the old folders are kept, renamed.
old = tempfile.mkdtemp()
os.makedirs(os.path.join(old, "notes"))
os.makedirs(os.path.join(old, "history", site))
json.dump(note(site, "example.com", 5), open(os.path.join(old, "notes", site + ".json"), "w"))
json.dump(note(site, "example.com", 4), open(os.path.join(old, "history", site, "2026-10-01.json"), "w"))
json.dump({site: {"updatedAt": 5, "vector": [0.5, 0.25]}}, open(os.path.join(old, "embeddings.json"), "w"))
old_env = {**os.environ, "MEMORYNOTES_DIR": old}
assert [n["id"] for n in call({"op": "list", "url": "example.com/"}, old_env)["notes"]] == [site]
assert not os.path.exists(os.path.join(old, "notes")) and os.path.exists(os.path.join(old, "notes.imported"))
assert os.path.exists(os.path.join(old, "history.imported")) and os.path.exists(os.path.join(old, "embeddings.json.imported"))
with sqlite3.connect(os.path.join(old, "memorynotes.sqlite")) as db:
    assert db.execute("SELECT day, body_md FROM snapshots").fetchall() == [("2026-10-01", "hi example.com")]
    assert struct.unpack("<2f", db.execute("SELECT vector FROM embeddings").fetchone()[0]) == (0.5, 0.25)
assert [n["id"] for n in call({"op": "list", "url": "example.com/"}, old_env)["notes"]] == [site], "second open must not re-import"
print("host ok")
