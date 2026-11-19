// node --test worker/
import { test } from "node:test";
import assert from "node:assert/strict";
import { feedbackEmail, mime } from "./feedback.js";

test("a good message becomes an email", () => {
  const m = feedbackEmail({ kind: "problem", message: "Panel opens twice\nsteps…", email: "a@b.co", app: "NoteAnywhere 0.1.2, macOS 26.2" });
  assert.equal(m.subject, "NoteAnywhere problem: Panel opens twice");
  assert.equal(m.replyTo, "a@b.co");
  assert.match(m.text, /Problem from NoteAnywhere 0\.1\.2/);
});

test("bad input is refused with a reason", () => {
  assert.ok(feedbackEmail({ kind: "spam", message: "x" }).error);
  assert.ok(feedbackEmail({ kind: "idea", message: "  " }).error);
  assert.ok(feedbackEmail({ kind: "idea", message: "x".repeat(5001) }).error);
  assert.ok(feedbackEmail({ kind: "idea", message: "x", email: "nope" }).error);
});

test("headers can't be injected", () => {
  const m = feedbackEmail({ kind: "idea", message: "hi\r\nBcc: x@y.z", email: "a@b.co\r\nBcc: x@y.z" });
  assert.ok(m.error || !m.replyTo.includes("\n"));
  const raw = mime({ ...feedbackEmail({ kind: "idea", message: "héllo ✓" }), from: "f@n.app", to: "t@g.com", id: "1", date: new Date(0) });
  assert.equal(raw.split("\r\n\r\n")[0].split("\r\n").filter((l) => l.startsWith("Bcc")).length, 0);
  assert.match(raw, /Subject: =\?UTF-8\?B\?/);
});
