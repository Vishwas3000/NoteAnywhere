"""End-to-end check of the Windows app as the browsers' native messaging host: starts NoteAnywhere.exe the way Chrome and
Firefox start it and frames JSON as they do, against a scratch store. The Windows twin of scripts/test_host.py.

    python windows/scripts/test_host.py out\\NoteAnywhere.exe    (NOTEANYWHERE_DIR: the store; a new temp folder if unset)
"""
import base64, http.server, json, os, queue, sqlite3, struct, subprocess, sys, tempfile, threading

EXE = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else r"out\NoteAnywhere.exe")
env = {**os.environ, "NOTEANYWHERE_DIR": os.environ.get("NOTEANYWHERE_DIR") or tempfile.mkdtemp()}
STORE = env["NOTEANYWHERE_DIR"]
DB = os.path.join(STORE, "memorynotes.sqlite")

# Chrome (Edge, Brave…) starts a host through cmd.exe, with the extension's origin and its window; Firefox starts it
# itself, with the path of the manifest it read (BrowserRegistration's, beside the notes) and the add-on's id.
CHROME = f'cmd.exe /d /s /c ""{EXE}" chrome-extension://fngldbimlphnokkkkodneojgbdnofjha/ --parent-window=0"'
FIREFOX = [EXE, os.path.join(STORE, "com.memorynotes.host.firefox.json"), "noteanywhere@noteanywhere.app"]


def frame(msg):
    body = json.dumps(msg).encode()
    return struct.pack("<I", len(body)) + body


def read(stream):
    header = stream.read(4)
    assert len(header) == 4, "the host closed its output"
    (n,) = struct.unpack("<I", header)
    return json.loads(stream.read(n))


def call(msg, how=CHROME):
    global said
    done = subprocess.run(how, input=frame(msg), capture_output=True, env=env, timeout=120)
    said = done.stderr.decode(errors="replace")  # the host's reasons (stdout is for replies), for failure messages
    out = done.stdout
    (n,) = struct.unpack("<I", out[:4])
    assert len(out) == 4 + n, out[:300]  # the reply, and nothing else on stdout
    return json.loads(out[4:])


def note(id, target, t=1, kind="url"):
    return {"id": id, "kind": kind, "target": target, "label": target, "text": "hi " + target, "createdAt": t, "updatedAt": t}


def ids(url, how=CHROME):
    return [n["id"] for n in call({"op": "list", "url": url}, how)["notes"]]


# Save, list, list again: a page shows its own notes and those of pages under it, never its parents'.
site = "aaaaaaaa-0000-0000-0000-000000000001"
page = "aaaaaaaa-0000-0000-0000-000000000002"
assert ids("github.com/") == []
assert call({"op": "save", "note": note(site, "github.com", 1)})["ok"]
assert call({"op": "save", "note": note(page.upper(), "github.com/vercel/next.js", 2)}, FIREFOX)["note"]["id"] == page
assert ids("github.com/") == [site, page]
assert ids("github.com/vercel") == [page]
assert ids("github.com/vercel/next.js/") == [page]
assert ids("github.com/vercel/next.jsx") == []
assert ids("github.com/", FIREFOX) == [site, page]
assert ids("github.company.com/") == []
listed = call({"op": "list", "url": "github.com/"})
assert listed["autoOpen"] is True and listed["datePattern"], listed

assert not call({"op": "save", "note": note("../../evil", "x.com")})["ok"], "non-UUID ids must be rejected"
assert not call({"op": "save", "note": note(site, "x.com", kind="app")})["ok"], "the browser can't write app notes"
assert call({"op": "nope"}) == {"ok": False, "error": "unknown op nope"}

# A watching port (connectNative) hears of another process's save, so edits reach open tabs live; closing it ends the host.
watcher = subprocess.Popen(CHROME, stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
watcher.stdin.write(frame({"op": "watch"}))
watcher.stdin.flush()
assert read(watcher.stdout) == {"ok": True}
heard = queue.Queue()
threading.Thread(target=lambda: heard.put(read(watcher.stdout)), daemon=True).start()
assert call({"op": "save", "note": note(site, "github.com", 6)})["ok"]
assert heard.get(timeout=10) == {"ok": True, "event": "changed"}, "no change event within 10 s"
watcher.stdin.close()
ended = threading.Thread(target=watcher.stdout.read, daemon=True)
ended.start()
ended.join(10)
assert not ended.is_alive(), "the host kept running after the browser closed its pipe"
watcher.wait(timeout=10)

# Delete is a tombstone: hidden from lists, kept for sync, and a late save from an open tab can't revive it.
assert call({"op": "delete", "id": page.upper()})["ok"]  # a panel opened before D76 may hold capitals
assert ids("github.com/") == [site]
assert call({"op": "save", "note": note(page, "github.com/vercel/next.js", 3)})["ok"]
assert ids("github.com/") == [site]
with sqlite3.connect(DB) as db:
    assert db.execute("SELECT deleted_at IS NOT NULL FROM notes WHERE id = ?", (page,)).fetchone() == (1,)

# Images (D53): kept by the host, read back in pieces whose base64 fits Chrome's 1 MB reply cap.
big = os.urandom(1_300_000)
added = call({"op": "addImage", "mime": "image/png", "data": base64.b64encode(big).decode()})
assert added["ok"] and added["src"].startswith("noteimage:"), added
image_id = added["src"].split(":", 1)[1]
pieces, got = [], 0
while got < len(big):
    r = call({"op": "image", "id": image_id, "offset": got})
    assert r["ok"] and r["mime"] == "image/png" and r["size"] == len(big), {k: v for k, v in r.items() if k != "data"}
    assert len(json.dumps(r, separators=(",", ":"))) < 1024 * 1024
    pieces.append(base64.b64decode(r["data"]))
    got += len(pieces[-1])
assert b"".join(pieces) == big and len(pieces) == 3
assert "can't hold" in call({"op": "addImage", "mime": "image/svg+xml", "data": "PHN2Zz4="})["error"]
assert not call({"op": "image", "id": "../memorynotes.sqlite"})["ok"], "only image ids"

assert call({"op": "ai", "action": "proofread", "text": "teh meeting"})["error"].startswith("The writing model isn't on this PC yet")


# Link previews: the page one redirect on, its favicon.ico (two sizes) and BMP picture made PNGs by WPF's decoders.
def ico(*sizes):
    images = [struct.pack("<IiiHHIIiiII", 40, s, 2 * s, 1, 32, 0, 0, 0, 0, 0, 0) + b"\x00\x00\xff\xff" * s * s
              + bytes((s + 31) // 32 * 4 * s) for s in sizes]  # header, red pixels, an AND mask that hides none
    out, offset = struct.pack("<HHH", 0, 1, len(sizes)), 6 + 16 * len(sizes)
    for s, image in zip(sizes, images):
        out += struct.pack("<BBBBHHII", s % 256, s % 256, 0, 0, 1, 32, len(image), offset)
        offset += len(image)
    return out + b"".join(images)


def bmp(width, height):
    stride = (width * 3 + 3) // 4 * 4
    pixels = (b"\xff\x00\x00" * width + bytes(stride - width * 3)) * height
    return (struct.pack("<2sIHHI", b"BM", 54 + len(pixels), 0, 0, 54)
            + struct.pack("<IiiHHIIiiII", 40, width, height, 1, 24, 0, len(pixels), 2835, 2835, 0, 0) + pixels)


PAGES = {
    "/page/": b'<html><head><title>Host test</title><meta property="og:description" content="A page &amp; its pictures">'
              b'<link rel="icon" href="icon.ico"><meta property="og:image" content="picture.bmp"></head></html>',
    "/page/icon.ico": ico(16, 32),
    "/page/picture.bmp": bmp(3, 2),
}


class Site(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/start":
            self.send_response(302)
            self.send_header("Location", "/page/")
            self.end_headers()
        elif self.path in PAGES:
            self.send_response(200)
            self.send_header("Content-Length", str(len(PAGES[self.path])))
            self.end_headers()
            self.wfile.write(PAGES[self.path])
        else:
            self.send_error(404)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Site)
threading.Thread(target=server.serve_forever, daemon=True).start()
reply = call({"op": "linkPreview", "url": f"http://127.0.0.1:{server.server_port}/start"})
assert reply["ok"], reply
preview, preview_said = reply["preview"], said
if said.strip():
    print("the host said:", said.strip())  # a download tried once more shows here even when the check passes
assert (preview["title"], preview["description"]) == ("Host test", "A page & its pictures"), preview


def png_width(src):
    assert src.startswith("noteimage:"), f"a picture wasn't kept: {preview}\nthe host said: {preview_said}"
    r = call({"op": "image", "id": src.split(":", 1)[1]})
    png = base64.b64decode(r["data"])
    assert r["mime"] == "image/png" and png[:8] == b"\x89PNG\r\n\x1a\n", r["mime"]
    return struct.unpack(">I", png[16:20])[0]  # IHDR's width


assert png_width(preview["icon"]) == 32, "not the icon's largest frame"
assert png_width(preview["image"]) == 3
print("host ok")
