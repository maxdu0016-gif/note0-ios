// note0 AI proxy — a Cloudflare Worker (free plan is enough to start).
//
// The iPad app sends OpenAI-style /v1/chat/completions requests here with a
// shared app token; this worker swaps in the real API key (kept only on
// Cloudflare) and streams the answer back. Students never see your key and
// don't need an account.
//
// Settings → Variables and Secrets (add as "Secret"):
//   UPSTREAM_API_KEY   your OpenAI / 通义千问 / OpenRouter key
//   APP_TOKEN          any long random string; also goes in the app's
//                      Info.plist as Note0AIProxyToken
// Optional plain variables:
//   UPSTREAM_BASE_URL  default https://api.openai.com/v1
//                      (通义千问: https://dashscope.aliyuncs.com/compatible-mode/v1)
//   ALLOWED_MODELS     comma separated, first one is the default; default gpt-5-mini

const json = (status, message) =>
  new Response(JSON.stringify({ error: { message } }), {
    status,
    headers: { "Content-Type": "application/json" },
  });

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (!url.pathname.endsWith("/chat/completions")) return json(404, "not found");
    if (request.method !== "POST") return json(405, "method not allowed");

    const auth = request.headers.get("Authorization") || "";
    if (!env.APP_TOKEN || auth !== `Bearer ${env.APP_TOKEN}`) return json(401, "invalid app token");
    if (!env.UPSTREAM_API_KEY) return json(500, "UPSTREAM_API_KEY is not set");

    let body;
    try {
      body = await request.json();
    } catch {
      return json(400, "invalid JSON");
    }

    // Only allow the models you chose, so a leaked token can't run expensive ones.
    const allowed = (env.ALLOWED_MODELS || "gpt-5-mini").split(",").map((m) => m.trim()).filter(Boolean);
    if (!allowed.includes(body.model)) body.model = allowed[0];

    const base = (env.UPSTREAM_BASE_URL || "https://api.openai.com/v1").replace(/\/+$/, "");
    const upstream = await fetch(`${base}/chat/completions`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${env.UPSTREAM_API_KEY}`,
      },
      body: JSON.stringify(body),
    });

    return new Response(upstream.body, {
      status: upstream.status,
      headers: {
        "Content-Type": upstream.headers.get("Content-Type") || "application/json",
        "Cache-Control": "no-cache",
      },
    });
  },
};
