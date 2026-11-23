"""The extension in a real Firefox (headless), on a scratch store, never your notes (D81): the panel opens by itself on a
page with notes, shows the note and its image through the native host, saves typing, updates live when a note is saved
elsewhere, and follows an in-page navigation. Firefox gives the panel's frame no tabs or native messaging and passes it
no messages, so this is where the background's relay and the panel's port get exercised.

Needs Firefox and Selenium (python3 -m pip install selenium; Selenium fetches geckodriver itself), and a release build:
  swift build -c release && python3 scripts/test_firefox.py [path/to/Firefox.app]
Firefox reads host manifests only from ~/Library/Application Support/Mozilla/NativeMessagingHosts, so the test puts its
own there for the run and puts back whatever was there before."""
import base64, json, os, pathlib, shutil, struct, subprocess, sys, tempfile, time
from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.firefox.options import Options

REPO = pathlib.Path(__file__).resolve().parent.parent
FIREFOX = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/Applications/Firefox.app") / "Contents/MacOS/firefox"
BUILD = REPO / ".build/release"
tmp = pathlib.Path(tempfile.mkdtemp(prefix="mn-firefox-"))
store, binary = tmp / "store", tmp / "MemoryNotes"
# A copy outside ~/Documents (no "access Documents?" prompt), with the Sparkle it loads through @loader_path.
shutil.copy(BUILD / "MemoryNotes", binary)
shutil.copytree(BUILD / "Sparkle.framework", tmp / "Sparkle.framework", symlinks=True)
wrapper = tmp / "host.sh"
wrapper.write_text(f'#!/bin/sh\nMEMORYNOTES_DIR="{store}" exec "{binary}" "$@"\n')
wrapper.chmod(0o755)

def host(msg):
    body = json.dumps(msg).encode()
    out = subprocess.run([str(binary), "chrome-extension://test/"], input=struct.pack("<I", len(body)) + body,
                         capture_output=True, env={**os.environ, "MEMORYNOTES_DIR": str(store)}, timeout=60).stdout
    return json.loads(out[4:])

PAGE = "127.0.0.1:8768/notes.html"
PNG = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAYAAAD0In+KAAAAEUlEQVR42mP4z8DwHwyB+AMAYMQK9v1ByAoAAAAASUVORK5CYII="  # 2×1
first = {"id": "eeeeeeee-0000-0000-0000-000000000001", "kind": "url", "target": PAGE, "label": "Page",
         "text": "Diagram\n\n![](%s)" % host({"op": "addImage", "mime": "image/png", "data": PNG})["src"],
         "createdAt": 1, "updatedAt": 1}
assert host({"op": "save", "note": first})["ok"]

site = tmp / "site"
site.mkdir()
for name in ["plain", "notes"]:
    (site / f"{name}.html").write_text("<!doctype html><title>Page</title><p>A page")

# The Firefox package, made the way scripts/release.sh makes it.
ext = tmp / "ext"
ext.mkdir()
for f in ["background.js", "content.js", "overlay.html", "overlay.js", "editor", "icons"]:
    (shutil.copytree if (REPO / "extension" / f).is_dir() else shutil.copy)(REPO / "extension" / f, ext / f)
m = json.loads((REPO / "extension/manifest.json").read_text())
del m["key"], m["background"]["service_worker"]
(ext / "manifest.json").write_text(json.dumps(m, indent=2))

hosts = pathlib.Path.home() / "Library/Application Support/Mozilla/NativeMessagingHosts"
manifest = hosts / "com.memorynotes.host.json"
made = [d for d in (hosts.parent, hosts) if not d.exists()]
before = manifest.read_bytes() if manifest.exists() else None
hosts.mkdir(parents=True, exist_ok=True)
manifest.write_text(json.dumps({"name": "com.memorynotes.host", "description": "test", "path": str(wrapper),
                                "type": "stdio", "allowed_extensions": ["noteanywhere@noteanywhere.app"]}))
results, server, driver = [], None, None

def check(label, ok, detail=""):
    print("PASS" if ok else "FAIL", label, detail)
    results.append(bool(ok))

def wait(fn, timeout=8):
    end = time.time() + timeout
    while time.time() < end:
        try:
            if value := fn():
                return value
        except Exception:
            pass
        time.sleep(0.25)
    return None

opts = Options()
opts.binary_location = str(FIREFOX)
opts.add_argument("-headless")
opts.set_preference("extensions.background.idle.timeout", 3000)  # the panel's port must keep the background up
try:
    server = subprocess.Popen([sys.executable, "-m", "http.server", "8768", "--bind", "127.0.0.1", "-d", str(site)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    driver = webdriver.Firefox(options=opts)
    print("Firefox", driver.capabilities.get("browserVersion"))
    driver.install_addon(str(ext), temporary=True)
    driver.get("http://" + PAGE)
    frame = wait(lambda: next((f for f in driver.find_elements(By.CSS_SELECTOR, "iframe[title=NoteAnywhere]")
                               if f.value_of_css_property("display") != "none"), None))
    check("the panel opens by itself on a page with notes", frame)
    if frame:
        driver.switch_to.frame(frame)
        body = lambda: driver.find_element(By.TAG_NAME, "body").text
        check("it shows the page's note", wait(lambda: "Diagram" in body()))
        img = wait(lambda: driver.execute_script(
            "const i = document.querySelector('.ProseMirror img'); return i?.complete && {blob: i.src.startsWith('blob:'), width: i.naturalWidth};"))
        check("the note's image loads through the host", img and img["blob"] and img["width"] == 2, img)

        editor = driver.find_element(By.CSS_SELECTOR, ".ProseMirror")
        editor.click()
        driver.execute_script("getSelection().selectAllChildren(arguments[0]); getSelection().collapseToEnd();", editor)
        editor.send_keys(" typed in Firefox")
        check("typing is saved through the host", wait(lambda: "typed in Firefox" in next(
            n["text"] for n in host({"op": "list", "url": PAGE})["notes"] if n["id"] == first["id"])))
        driver.execute_script("document.activeElement.blur()")  # the panel never reloads under your cursor

        time.sleep(9)  # three times the background's idle timeout
        now = int(time.time() * 1000)
        assert host({"op": "save", "note": {**first, "id": "eeeeeeee-0000-0000-0000-000000000002", "label": "Second",
                                            "text": "Saved by the app", "createdAt": now, "updatedAt": now}})["ok"]
        check("a note saved elsewhere shows up live, after the background sat idle", wait(lambda: "Saved by the app" in body(), 10))
        driver.switch_to.default_content()

        # In-page navigation (content.js → background → the panel's port): a page without notes closes the panel.
        driver.execute_script("history.pushState({}, '', '/plain.html')")
        check("an in-page move to a page without notes closes the panel", wait(lambda: driver.find_element(
            By.CSS_SELECTOR, "iframe[title=NoteAnywhere]").value_of_css_property("display") == "none", 6))
finally:
    if driver:
        driver.quit()
    if server:
        server.terminate()
    if before is None:
        manifest.unlink()
    else:
        manifest.write_bytes(before)
    for d in reversed(made):
        d.rmdir()
    shutil.rmtree(tmp, ignore_errors=True)
print(f"{sum(results)}/{len(results)} passed")
sys.exit(0 if results and all(results) else 1)
