// noteanywhere.app: static files come from ./site before this runs; it only answers what isn't a file (D71, D72).
import { EmailMessage } from "cloudflare:email";
import { feedbackEmail, mime } from "./feedback.js";

const FROM = "feedback@noteanywhere.app";
const TO = "timeupvishwa@gmail.com";
const json = (status, body) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== "/api/feedback") return env.ASSETS.fetch(request);
    if (request.method !== "POST") return json(405, { error: "Use POST." });

    const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
    if (!(await env.LIMIT.limit({ key: ip })).success) return json(429, { error: "Too many messages. Try again in a minute." });

    let body;
    try { body = await request.json(); } catch { return json(400, { error: "Send the form as JSON." }); }
    if (body?.company) return json(200, { ok: true });  // the website's hidden field: only bots fill it in

    const mail = feedbackEmail(body);
    if (mail.error) return json(400, { error: mail.error });
    try {
      const raw = mime({ ...mail, from: FROM, to: TO, id: crypto.randomUUID(), date: new Date() });
      await env.FEEDBACK.send(new EmailMessage(FROM, TO, raw));
    } catch (e) {
      console.error("feedback send failed", e);
      return json(502, { error: "The message couldn't be sent. Try again later." });
    }
    return json(200, { ok: true });
  },
};
