/**
 * Sierra Morning Dashboard — Goals + HR Worker
 * --------------------------------------------
 * A tiny, dependency-free Cloudflare Worker that stores editable goal values for the
 * dashboard's progress bars in Workers KV. The dashboard is a static site (GitHub Pages),
 * so it has no server of its own — this Worker is the only piece that persists goals and
 * enforces the shared edit password SERVER-SIDE (the password is never shipped to the page).
 *
 * It ALSO serves the HR & Payroll section, which is a completely separate world: separate KV
 * namespace, separate password, separate CORS policy, separate session tokens. See "HR SECTION"
 * below for why the separation is absolute.
 *
 * Bindings (see wrangler.toml):
 *   - KV namespace `GOALS`         : stores a single JSON object under the key "goals".
 *   - KV namespace `HR_KV`         : stores the HR blob under "hr-state", plus session tokens
 *                                    and unlock rate-limit counters. NEVER shares with GOALS.
 *   - secret       `EDIT_PASSWORD` : the shared goal-edit password.
 *   - secret       `HR_PASSWORD`   : the HR password. Different value from EDIT_PASSWORD.
 *                                    (Set both via `wrangler secret put <NAME>`.)
 *
 * Routes:
 *   OPTIONS *        → CORS preflight (204). /hr/* gets the STRICT origin policy; others permissive.
 *   GET     /goals   → returns the goals object from KV (default {} if unset). OPEN, no auth.
 *   POST    /goals   → header `X-Edit-Password` must equal EDIT_PASSWORD. Body {key,value}.
 *                      On match + a numeric value that is IN RANGE for that key's goal kind (see
 *                      GOAL_KINDS/GOAL_RANGES below) → merge {key:value} into KV, return 200
 *                      + the updated goals object. Wrong/missing password → 401. Bad input → 400.
 *   POST    /hr/unlock → body {password}. Rate-limited. On match returns a session token.
 *   GET     /hr/data   → header `X-HR-Token` must be a live session. Returns the "hr-state" blob.
 *   POST    /hr/data   → same auth. Body must be a JSON object. Replaces "hr-state".
 *
 * Design notes:
 *   - CORS for /goals is permissive: it reflects the caller's Origin (so any origin can read or
 *     attempt writes). That is safe there because GET is public by design and POST is gated by the
 *     server-side password — an attacker with no password can change nothing.
 *   - CORS for /hr/* is NOT permissive. See ALLOWED_HR_ORIGIN.
 *   - Fail loud: bad input and server errors return an explicit JSON { error } with a 4xx/5xx code,
 *     never a silent success or a made-up value.
 */

const KV_KEY = "goals";

/* ===========================================================================
 * GOAL VALUE RANGES — the AUTHORITATIVE check. The dashboard validates too (in its editor and
 * again at render time), but that copy runs in the browser and can be bypassed, so nothing is
 * trusted until it has passed through here.
 *
 * !!! KEEP `GOAL_KINDS` BELOW IN SYNC WITH `GOAL_META` IN dashboard.html !!!  Same keys, same
 *     kinds, same three ranges. Adding a bar means adding its key in BOTH places.
 * !!! WORKER CHANGES ARE NOT LIVE UNTIL `wrangler deploy` RUNS. !!!  Editing this file alone
 *     changes nothing in production.
 *
 * Zero and negatives are rejected for every kind: the dashboard's goalBar() treats 0 as "no goal
 * set", so storing a 0 would make the page show the "+ Set goal" affordance again and look like the
 * save silently did nothing. Money ceiling: the largest real YTD figure in this business is HVAC
 * Sales at ~$28.5M, so $100M leaves ~3.5x headroom for growth while still catching a fat-finger
 * extra digit. A rate goal is 0-100 by definition; a day's booked calls are in the hundreds.
 * =========================================================================== */
const GOAL_KINDS = {
  "plumbing-rev-ytd": "money",
  "hvac-sales-ytd": "money",
  "silo-rev-ytd": "money",
  "calls-booked-today": "count",
};
/* `percent` currently has no key mapped to it: silo-flip-ytd was removed on 2026-08-11 because the
 * SILO flip arc gauges already carry a target tick and an ahead/behind delta, so a straight goal bar
 * repeated the same comparison. The range is kept so that adding a future percentage goal is a
 * one-line change here, and so the definition of "a valid percentage goal" does not have to be
 * re-derived. Any value still stored in KV under silo-flip-ytd is ORPHANED - nothing reads it, and
 * note that it is now covered only by the generic guard below, not by the 0-100 percent range. */
const GOAL_RANGES = {
  money: { max: 100000000, desc: "a dollar amount greater than 0 and at most 100,000,000" },
  percent: { max: 100, desc: "a percentage greater than 0 and at most 100" },
  count: { max: 10000, desc: "a count greater than 0 and at most 10,000" },
};
/* An UNKNOWN key is deliberately NOT rejected outright: that would be a deploy-order trap where a
 * new bar added to dashboard.html could not be used until this Worker was redeployed. Instead it
 * gets the strictest generic guard (>0, <= the money ceiling), which still stops a fat-finger. */
const GENERIC_MAX = 100000000;

/** null when `num` is a valid goal for `key`; otherwise the 400 message, naming the valid range. */
function goalRangeError(key, num) {
  const kind = GOAL_KINDS[key];
  const range = kind
    ? GOAL_RANGES[kind]
    : { max: GENERIC_MAX, desc: "a number greater than 0 and at most 100,000,000 (unrecognised goal key '" + key + "': generic guard applied)" };
  if (num <= 0) {
    return "invalid 'value': " + num + " is out of range for '" + key + "' - expected " + range.desc +
      " (0 means \"no goal set\" to the dashboard, so it is never stored as a goal)";
  }
  if (num > range.max) {
    return "invalid 'value': " + num + " is out of range for '" + key + "' - expected " + range.desc;
  }
  return null;
}

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

/* ===========================================================================
 * HR SECTION
 * ===========================================================================
 * EVERYTHING BELOW TOUCHES SALARY AND EMPLOYEE DATA. Three rules hold it together:
 *
 *   1. SEPARATE NAMESPACE. HR lives in `HR_KV`, never in `GOALS`. The goals password is typed by
 *      several people and is a low-value secret; it must never be able to reach HR data. Because
 *      the two namespaces are distinct bindings, a bug in the goals path CANNOT read or write HR
 *      keys even if the password check there were bypassed entirely.
 *   2. SEPARATE ORIGIN POLICY. /goals reflects any Origin. /hr/* answers ONE origin (see below).
 *   3. NOTHING HR EVER REACHES THE REPO. This repository is PUBLIC and git history is permanent.
 *      HR values live only in KV. Do not add HR fixtures, sample payloads, or test data to any
 *      file in this repo — not even fake-looking ones, because a plausible fake is indistinguishable
 *      from a leak to anyone reading the history later.
 * =========================================================================== */

/* The ONLY browser origin allowed to call /hr/*. A browser sends just scheme+host in `Origin`, so
 * the repo path (/sierra-dashboard/) is deliberately absent. "*" is forbidden here: with "*" any
 * web page you happened to visit could script requests to these routes using your session.
 *
 * CONSEQUENCE WORTH KNOWING: the HR section will only work on the live GitHub Pages site. Opening
 * dashboard.html from your own hard drive, or from a local server, will be refused by the browser.
 * That is the policy doing its job, not a bug. */
const ALLOWED_HR_ORIGIN = "https://troyputman.github.io";

const HR_STATE_KEY = "hr-state";       // the single blob GET/POST /hr/data reads and writes
const HR_SESSION_PREFIX = "session:";  // + token  -> a live session
const HR_RATELIMIT_PREFIX = "rl:unlock:"; // + ip  -> failed-attempt counter

const HR_SESSION_TTL_SECONDS = 8 * 60 * 60;   // 8h: one working day, then you log in again.
const HR_UNLOCK_MAX_FAILURES = 10;            // failures allowed per IP per window
const HR_UNLOCK_WINDOW_SECONDS = 15 * 60;     // 15 min window
const HR_MAX_BODY_BYTES = 1024 * 1024;        // 1 MB cap on the HR blob (KV allows 25 MB; this is
                                              // a sanity guard so a runaway client cannot bloat KV)

/** Strict CORS for /hr/*: exactly one origin, and only the headers HR actually uses. */
function hrCorsHeaders() {
  return {
    "Access-Control-Allow-Origin": ALLOWED_HR_ORIGIN,
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, X-HR-Token",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}

/** JSON response helper for /hr/* — strict CORS, never cached. */
function hrJson(obj, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...hrCorsHeaders(),
    },
  });
}

/* The ONLY body ever returned for a failed unlock or a bad session. Deliberately identical for
 * every failure mode - wrong password, missing password, empty password, expired token, forged
 * token. Anything that varied by cause would tell an attacker which guesses were "warmer". */
const HR_DENIED = { error: "unauthorized" };

/** Compare two strings without leaking, through timing, HOW MUCH of the password matched.
 *  A plain `a !== b` stops at the first differing byte, so a closer guess takes measurably longer.
 *  This walks the full length every time. Overkill for a remote attacker, cheap enough to just do. */
function timingSafeEqual(a, b) {
  const enc = new TextEncoder();
  const ab = enc.encode(String(a));
  const bb = enc.encode(String(b));
  let diff = ab.length ^ bb.length;          // length mismatch alone forces a non-zero result
  const n = Math.max(ab.length, bb.length);
  for (let i = 0; i < n; i++) {
    diff |= (ab[i] || 0) ^ (bb[i] || 0);
  }
  return diff === 0;
}

/** 256 bits of cryptographic randomness as 64 hex chars. Not guessable, not derived from anything. */
function newSessionToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Caller's IP as Cloudflare sees it. Cloudflare sets this itself, so a client cannot spoof it. */
function clientIp(request) {
  return request.headers.get("CF-Connecting-IP") || "unknown";
}

/** How many failed unlocks this IP has made inside the current window. 0 when clean. */
async function unlockFailureCount(env, ip) {
  const raw = await env.HR_KV.get(HR_RATELIMIT_PREFIX + ip);
  const n = raw ? parseInt(raw, 10) : 0;
  return Number.isFinite(n) && n > 0 ? n : 0;
}

/** Record one more failure for this IP. The TTL restarts on each failure, so sustained guessing
 *  keeps the door shut rather than letting the window quietly lapse mid-attack. */
async function recordUnlockFailure(env, ip, currentCount) {
  await env.HR_KV.put(HR_RATELIMIT_PREFIX + ip, String(currentCount + 1), {
    expirationTtl: HR_UNLOCK_WINDOW_SECONDS,
  });
}

/** true when the request carries a live session token. Shape-checks before hitting KV so that
 *  junk tokens cost nothing. KV expiry does the session timeout for us - no clock code here. */
async function hasValidSession(request, env) {
  const token = request.headers.get("X-HR-Token") || "";
  if (!/^[0-9a-f]{64}$/.test(token)) return false;   // not even the right shape
  const raw = await env.HR_KV.get(HR_SESSION_PREFIX + token);
  return raw !== null;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const isHr = url.pathname === "/hr/unlock" || url.pathname === "/hr/data";

    // ---- CORS preflight -------------------------------------------------
    // HR preflights get the strict single-origin policy; everything else keeps the existing
    // permissive behaviour. Goals behaviour is unchanged.
    if (request.method === "OPTIONS") {
      if (isHr) {
        return new Response(null, { status: 204, headers: hrCorsHeaders() });
      }
      return new Response(null, { status: 204, headers: corsHeaders(request) });
    }

    // =====================================================================
    // HR ROUTES — handled before /goals so the 404 guard below never sees them.
    // =====================================================================
    if (isHr) {
      // Fail loud on misconfiguration. An HR route that quietly returned {} because its KV binding
      // was missing would look exactly like "no employees on file", which is the worst possible lie.
      if (!env.HR_KV || typeof env.HR_KV.get !== "function") {
        return hrJson({ error: "server misconfigured: KV binding HR_KV is missing" }, 500);
      }

      // ---- POST /hr/unlock : password -> session token -------------------
      if (url.pathname === "/hr/unlock") {
        if (request.method !== "POST") {
          return hrJson({ error: "method not allowed" }, 405);
        }
        const expected = env.HR_PASSWORD || "";
        if (!expected) {
          return hrJson({ error: "server misconfigured: HR_PASSWORD secret is not set" }, 500);
        }

        // Rate limit BEFORE looking at the password, so a blocked IP learns nothing by guessing.
        const ip = clientIp(request);
        let failures;
        try {
          failures = await unlockFailureCount(env, ip);
        } catch (e) {
          // Cannot verify the limit -> refuse. Failing open here would remove the brute-force guard
          // at exactly the moment it is most likely to be under load.
          return hrJson({ error: "rate-limit check failed: " + (e && e.message ? e.message : String(e)) }, 500);
        }
        if (failures >= HR_UNLOCK_MAX_FAILURES) {
          return hrJson(
            { error: "too many failed attempts - wait " + Math.ceil(HR_UNLOCK_WINDOW_SECONDS / 60) + " minutes and try again" },
            429
          );
        }

        let body;
        try {
          body = await request.json();
        } catch (_e) {
          return hrJson({ error: "body must be valid JSON { password }" }, 400);
        }
        const supplied = body && typeof body.password === "string" ? body.password : "";

        if (!timingSafeEqual(supplied, expected)) {
          try {
            await recordUnlockFailure(env, ip, failures);
          } catch (_e) {
            // A counter write failure must not turn a rejection into an acceptance. Swallow it and
            // still deny: worst case this one attempt went uncounted.
          }
          return hrJson(HR_DENIED, 401);   // identical for every wrong-password shape
        }

        // Correct password. Mint a session and let KV expire it for us.
        try {
          const token = newSessionToken();
          await env.HR_KV.put(
            HR_SESSION_PREFIX + token,
            JSON.stringify({ issuedAt: new Date().toISOString() }),
            { expirationTtl: HR_SESSION_TTL_SECONDS }
          );
          return hrJson({ token, expiresInSeconds: HR_SESSION_TTL_SECONDS }, 200);
        } catch (e) {
          // Could not persist the session -> do NOT hand back a token that will not work.
          return hrJson({ error: "failed to create session: " + (e && e.message ? e.message : String(e)) }, 500);
        }
      }

      // ---- /hr/data : session-gated read and write -----------------------
      if (url.pathname === "/hr/data") {
        let authed;
        try {
          authed = await hasValidSession(request, env);
        } catch (e) {
          return hrJson({ error: "session check failed: " + (e && e.message ? e.message : String(e)) }, 500);
        }
        if (!authed) {
          return hrJson(HR_DENIED, 401);
        }

        // ---- GET /hr/data ------------------------------------------------
        if (request.method === "GET") {
          let raw;
          try {
            raw = await env.HR_KV.get(HR_STATE_KEY);
          } catch (e) {
            return hrJson({ error: "failed to read HR data: " + (e && e.message ? e.message : String(e)) }, 500);
          }
          // Never written yet is a legitimate empty state, not an error - a brand-new setup has no
          // HR data and must be able to start from {}.
          if (raw === null) {
            return hrJson({}, 200);
          }
          // Stored but unreadable is a DIFFERENT situation and must NOT collapse into {}. Returning
          // an empty object here would render as "no employees" over the top of real data that is
          // still sitting in KV. Fail loud instead; the blob is recoverable, a bad overwrite is not.
          try {
            const parsed = JSON.parse(raw);
            if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
              return hrJson({ error: "stored HR data is not a JSON object - refusing to serve it" }, 500);
            }
            return hrJson(parsed, 200);
          } catch (_e) {
            return hrJson({ error: "stored HR data is corrupt (not valid JSON) - refusing to serve it" }, 500);
          }
        }

        // ---- POST /hr/data -----------------------------------------------
        if (request.method === "POST") {
          let text;
          try {
            text = await request.text();
          } catch (e) {
            return hrJson({ error: "could not read request body: " + (e && e.message ? e.message : String(e)) }, 400);
          }
          if (text.length > HR_MAX_BODY_BYTES) {
            return hrJson({ error: "HR data too large (limit " + HR_MAX_BODY_BYTES + " bytes) - nothing was written" }, 400);
          }
          let parsed;
          try {
            parsed = JSON.parse(text);
          } catch (_e) {
            return hrJson({ error: "body must be valid JSON - nothing was written" }, 400);
          }
          if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
            return hrJson({ error: "body must be a JSON object - nothing was written" }, 400);
          }
          try {
            // Re-serialise the PARSED value, so whatever lands in KV is guaranteed valid JSON.
            await env.HR_KV.put(HR_STATE_KEY, JSON.stringify(parsed));
            return hrJson({ ok: true, savedKeys: Object.keys(parsed).length }, 200);
          } catch (e) {
            return hrJson({ error: "failed to save HR data: " + (e && e.message ? e.message : String(e)) }, 500);
          }
        }

        return hrJson({ error: "method not allowed" }, 405);
      }
    }

    // =====================================================================
    // GOALS ROUTES — unchanged.
    // =====================================================================

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
      // Type-aware range check (see GOAL_KINDS/GOAL_RANGES above) — a percent goal of 30000000 is
      // rejected here even if the page's own checks were bypassed. Fail loud with the range.
      const rangeErr = goalRangeError(key, num);
      if (rangeErr) {
        return json(request, { error: rangeErr }, 400);
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
