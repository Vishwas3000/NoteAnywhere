"""End-to-end check of the native messaging host: frames JSON like Chrome does, against a temp notes folder."""
import json, os, struct, subprocess, sys, tempfile

BIN = sys.argv[1] if len(sys.argv) > 1 else ".build/release/MemoryNotes"
env = {**os.environ, "MEMORYNOTES_DIR": tempfile.mkdtemp()}

def call(msg):
    body = json.dumps(msg).encode()
    out = subprocess.run([BIN, "chrome-extension://test/"], input=struct.pack("<I", len(body)) + body,
                         capture_output=True, env=env, timeout=10).stdout
    (n,) = struct.unpack("<I", out[:4])
    assert len(out) == 4 + n, out
    return json.loads(out[4:])

def note(id, target, t=1):
    return {"id": id, "kind": "url", "target": target, "label": target, "text": "hi " + target, "createdAt": t, "updatedAt": t}

site = "aaaaaaaa-0000-0000-0000-000000000001"
page = "aaaaaaaa-0000-0000-0000-000000000002"
assert call({"op": "save", "note": note(site, "github.com", 1)})["ok"]
assert call({"op": "save", "note": note(page, "github.com/vercel/next.js", 2)})["ok"]

ids = lambda url: [n["id"] for n in call({"op": "list", "url": url})["notes"]]
assert ids("github.com/") == [site]
assert ids("github.com/vercel/next.js") == [site, page]
assert ids("github.com/vercel/next.js/issues/1") == [site, page]
assert ids("github.com/vercel/next.jsx") == [site]
assert ids("github.company.com/") == []

assert not call({"op": "save", "note": note("../../evil", "x.com")})["ok"], "path traversal must be rejected"
assert not call({"op": "save", "note": {**note(site, "x.com"), "kind": "app"}})["ok"], "browser can't write app notes"
assert not call({"op": "nope"})["ok"]

# Every save also writes that day's snapshot for the calendar; delete removes the history.
import datetime
day = datetime.date.today().isoformat()  # the host stamps updatedAt with "now"
assert os.path.exists(os.path.join(env["MEMORYNOTES_DIR"], "history", page, day + ".json"))

assert call({"op": "delete", "id": page})["ok"]
assert not os.path.exists(os.path.join(env["MEMORYNOTES_DIR"], "history", page))
assert ids("github.com/vercel/next.js") == [site]
print("host ok")
