/**
 * Sierra Morning Dashboard — Goals Worker
 * ---------------------------------------
 * A tiny, dependency-free Cloudflare Worker that stores editable goal values for the
 * dashboard's progress bars in Workers KV. The dashboard is a static site (GitHub Pages),
 * so it has no server of its own — this Worker is the only piece that persists goals and
 * enforces the shared edit password SERVER-SIDE (the password is never shipped to the page).
 *
 * Bindings (see wrangler.toml):
 *   - KV namespace `GOALS`         : stores a single JSON object under the key "goals".
 *   - secret       `EDIT_PASSWORD` : the shared edit password (set via `wrangler secret put`
 *                                    or the Cloudflare dashboard → Worker → Settings → Variables).
 *
 * Routes:
 *   OPTIONS *        → CORS preflight (204).
 *   GET     /goals   → returns the goals object from KV (default {} if unset). OPEN, no auth.
 *   POST    /goals   → header `X-Edit-Password` must equal EDIT_PASSWORD. Body {key,value}.
 *                      On match + valid numeric value → merge {key:value} into KV, return 200
 *                      + the updated goals object. Wrong/missing password → 401. Bad input → 400.
 *
 * Design notes:
 *   - CORS is permissive: it reflects the caller's Origin (so any origin can read/attempt writes).
 *     That is safe here because GET is public by design and POST is gated by the server-side
 *     password — an attacker with no password can change nothing.
 *   - Fail loud: bad input and server errors return an explicit JSON { error } with a 4xx/5xx code,
 *     never a silent success or a made-up value.
 */

const KV_KEY = "goals";

/** Build CORS headers that reflect the request Origin (permissive, but writes still need the password). */
function corsHeaders(request) {
  const origin = request.headers.get("Origin") || "*";
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, X-Edit-Password",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}

/** JSON response helper that always includes CORS + no-store caching. */
function json(request, obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...corsHeaders(request),
    },
  });
}

/** Read the goals object from KV. Returns {} if unset or if the stored value is not an object. */
async function readGoals(env) {
  const raw = await env.GOALS.get(KV_KEY);
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
  } catch (_e) {
    // Corrupt stored value — treat as empty rather than crash; a fresh write will heal it.
    return {};
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    // ---- CORS preflight -------------------------------------------------
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: corsHeaders(request) });
    }

    // Only the /goals route is served.
    if (url.pathname !== "/goals") {
      return json(request, { error: "not found" }, 404);
    }

    // Guard: the KV binding must exist, else fail loud (misconfiguration, not a real "no goals").
    if (!env.GOALS || typeof env.GOALS.get !== "function") {
      return json(request, { error: "server misconfigured: KV binding GOALS is missing" }, 500);
    }

    // ---- GET /goals : open read ----------------------------------------
    if (request.method === "GET") {
      try {
        const goals = await readGoals(env);
        return json(request, goals, 200);
      } catch (e) {
        return json(request, { error: "failed to read goals: " + (e && e.message ? e.message : String(e)) }, 500);
      }
    }

    // ---- POST /goals : password-gated write ----------------------------
    if (request.method === "POST") {
      // Password check first — compare to the server-side secret. Constant enough for our threat model.
      const supplied = request.headers.get("X-Edit-Password") || "";
      const expected = env.EDIT_PASSWORD || "";
      if (!expected) {
        return json(request, { error: "server misconfigured: EDIT_PASSWORD secret is not set" }, 500);
      }
      if (supplied !== expected) {
        return json(request, { error: "wrong password" }, 401);
      }

      // Parse + validate body: { key: string, value: finite number }.
      let body;
      try {
        body = await request.json();
      } catch (_e) {
        return json(request, { error: "body must be valid JSON { key, value }" }, 400);
      }
      const key = body && body.key;
      const value = body && body.value;
      if (typeof key !== "string" || key.trim() === "") {
        return json(request, { error: "invalid 'key': expected a non-empty string" }, 400);
      }
      const num = typeof value === "number" ? value : Number(value);
      if (!Number.isFinite(num)) {
        return json(request, { error: "invalid 'value': expected a finite number" }, 400);
      }

      // Merge and persist.
      try {
        const goals = await readGoals(env);
        goals[key] = num;
        await env.GOALS.put(KV_KEY, JSON.stringify(goals));
        return json(request, goals, 200);
      } catch (e) {
        return json(request, { error: "failed to save goal: " + (e && e.message ? e.message : String(e)) }, 500);
      }
    }

    return json(request, { error: "method not allowed" }, 405);
  },
};
