// Turns a feedback form (from the Mac app or the website) into a plain-text email, or says what's wrong with it (D72).
const KINDS = { problem: "Problem", idea: "Suggestion" };
const oneLine = (s, max) => String(s ?? "").replace(/[\r\n]+/g, " ").trim().slice(0, max);  // no header injection

export function feedbackEmail(body) {
  const kind = KINDS[body?.kind];
  const message = String(body?.message ?? "").trim();
  const email = oneLine(body?.email, 254);
  const from = oneLine(body?.app, 120) || "unknown";
  if (!kind) return { error: "Pick Problem or Suggestion." };
  if (!message) return { error: "Write a message first." };
  if (message.length > 5000) return { error: "Keep it under 5,000 characters." };
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return { error: "That email address doesn't look right." };
  const firstLine = oneLine(message.split("\n")[0], 60);
  return {
    subject: `NoteAnywhere ${kind.toLowerCase()}: ${firstLine}`,
    replyTo: email || null,
    text: `${message}\n\n--\n${kind} from ${from}\nReply to: ${email || "not given"}\n`,
  };
}

const b64 = (s) => btoa(String.fromCharCode(...new TextEncoder().encode(s)));

/** A minimal RFC 5322 message; UTF-8 subject and body travel base64-encoded. */
export function mime({ from, to, subject, replyTo, text, id, date }) {
  const lines = [
    `From: NoteAnywhere Feedback <${from}>`,
    `To: ${to}`,
    ...(replyTo ? [`Reply-To: ${replyTo}`] : []),
    `Subject: =?UTF-8?B?${b64(subject)}?=`,
    `Message-ID: <${id}@noteanywhere.app>`,
    `Date: ${date.toUTCString()}`,
    "MIME-Version: 1.0",
    "Content-Type: text/plain; charset=utf-8",
    "Content-Transfer-Encoding: base64",
    "",
    b64(text).replace(/.{76}/g, "$&\r\n"),
  ];
  return lines.join("\r\n");
}
