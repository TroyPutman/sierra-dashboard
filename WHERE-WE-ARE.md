# WHERE WE ARE — Sierra Morning Dashboard

**Status as of 2026-08-11.** This file is STATUS. `DECISIONS.md` is the business-rule record (every
definition + why); `HANDOFF-CURRENT.md` is what to do next; `SPEC.md` is per-metric build spec and is
stale for M2/M3/M4. Where SPEC.md and DECISIONS.md disagree, DECISIONS.md wins (CLAUDE.md rule 6).

> The previous version of this file was dated 2026-08-03 and was 61 commits behind — it predated the
> entire goal-bar system, the Revenue tab, the Call Board redesign and the SILO flip rebuild. It was
> replaced wholesale on 2026-08-11. The old text is in git history if you need it.

---

## WHAT SHIPPED (2026-08-10 → 2026-08-11)

Each item is anchored to its commit so you can read the real diff rather than trusting this summary.

| Commit | What |
|---|---|
| `cb49bf9` | **Cloudflare Worker + KV deployed.** Goal bars went live and editable; front-end pointed at the deployed Worker, KV namespace id set. Password gating is server-side — the password never ships to the page. |
| `e723232` | **Revenue tab cleanup + goal editor fixes.** Bigger whole-dollar figures (cents dropped in the hero numbers), notes collapsed behind "How this is calculated", the NOT FINAL caveat calmed to muted text with a small badge. Editor: value field moved above password, plain-text input, accepts typed commas and decimals. |
| `538a4c4` | **Goal bars switched MTD → YTD**, keys renamed (`*-mtd` → `*-ytd`). This is what orphaned three keys in KV — see Known Problems. |
| `d72e493` | **Call Board redesign.** Per-business-unit HVAC breakout, opportunity vs non-opportunity split, with the exclusion list config-driven via `callBoard.nonOpportunityJobTypeIds` (10 job-type ids). Fails loud if any id is not a real job type. |
| `e6578ee` | **Workflow retry loop for push collisions** — the commit-back step rebases and retries instead of failing when the 15-minute heartbeat collides with a manual push. |
| `ba652dc` | **SILO flip rate rebuilt to the SILO manager's method** — TGLs created / ROPP calls ran, replacing turnovers-sold / total-turnovers. Moved the figure ~10 points, from 38.5% to ~48.5% YTD. |
| `a8f4cd9` | **Type-aware goal validation + pace markers.** Ranges per goal kind, enforced in three places. Pace tick + AHEAD / ON PACE / BEHIND badge on cumulative money goals only. |
| `cae3c25` | **Error cooldown** so a failed flip build doesn't retry-storm the Reporting API. |
| `471919f` | **SILO revenue goal bar** (`silo-rev-ytd`) added. |
| `8a7ca47` | **Today/MTD/YTD arc gauges** replacing the flip cards, plus a TODAY period for the flip rate; **SILO flip goal bar removed** as redundant (the arcs already carry the target tick and delta). |

### The SILO flip number, verified against the manager

Live CI figures at 2026-08-11 15:30Z, and how they compare to the manager's own display:

| Period | Ours | Manager's |
|---|---:|---:|
| YTD | **48.46%** (2368 / 4887) | 48.4% |
| MTD | **67.05%** (175 / 261) | ~67.1% |

The MTD match is worth noting: `SILO-FLIP-HANDOFF.md` §9 listed the ~67.1% MTD as an **open gap** that
could not be reconciled (an earlier snapshot read 69.76%). It has since settled to 67.05%. That is
independent corroboration of the method, not tuning — nothing was adjusted to force it.

---

## CURRENT STATE

### Live and working
- All 9 metrics (M1–M9) build; the dashboard runs from `serve.ps1` (port 8787; the browser-preview
  helper in `.claude/launch.json` uses 8791) and deploys to GitHub Pages every 15 minutes, 24/7.
- **Goal bars** on Plumbing revenue, HVAC Sales, SILO revenue and calls-booked-today. All are straight
  horizontal bars. Money/count goals get a pace tick + AHEAD/ON PACE/BEHIND badge; pace is computed
  from the snapshot's own Pacific date string, never the browser clock.
- **SILO flip rate** as three arc gauges (Today / MTD / YTD), colour-coded against
  `config.json` → `siloFlip.targetRate` (60), with a tick on each arc at the target and a signed delta.
  Zero calls renders an empty arc + "no calls yet", which is visibly distinct from a genuine 0.0%.
- **Flip caching**: computed by `refresh-silo-flip.ps1` into `data/silo-flip.json`, never on request.
  Three clocks — `cacheTtlSeconds` 6h (full rebuild, 6 POSTs + ~42k-job pull, ~7–8 min),
  `todayTtlSeconds` 30m (today only, 2 POSTs + one-day jobs pull, ~1–2 min),
  `errorRetryCooldownSeconds` 1h (after a failure).
- Every tab fits 1920×1080 with no scroll. Verified for the Revenue tab at a true 1080 viewport as
  recently as 2026-08-11 (`documentElement.scrollHeight == 1080`, zero overflow).

### Still needs doing
1. **`wrangler deploy` the Worker.** `goals-worker/worker.js` has server-side range validation and the
   updated key→kind table committed but **NOT deployed**. Until then only the two client-side layers
   are active.
2. **Set the four unset goals** (see GOALS NOT SET).
3. **Reduce the silo-revenue POST volume** (see Known Problems #1). A task chip was spawned for this.
4. The DECIDED-BUT-NOT-BUILT queue in `DECISIONS.md` — M4 features, M5 window start, M6 per-house
   membership, M7 weekends, M9 roster derivation, dispatch/arrival, Overview calendar.
5. `SILO-FLIP-HANDOFF.md` still says "INVESTIGATION COMPLETE, NOT BUILT" with 4 POSTs and two periods.
   It is now built, with 6 POSTs and three periods. Worth marking so nobody repeats the investigation.

---

## KNOWN PROBLEMS — specific and honest

### 1. ~288 Reporting-API POSTs/day from silo-revenue, causing 429s
`Get-Metric-SiloRevenue` makes **three** Reporting API POSTs per snapshot (today/MTD/YTD against saved
report `648754648`). It is in `$METRIC_DEFS`, so `Build-Snapshot` calls it on **every** `refresh.ps1`
run, and the cron is every 15 minutes 24/7 → roughly **288 POSTs/day**. This tenant 429-throttles rapid
consecutive report POSTs with a ~60s backoff.

This is not theoretical. On **2026-08-11 at 14:52Z the SILO flip build failed with HTTP 429** on its
first POST after exhausting all 6 retries, and the dashboard showed a fail-loud error for ~40 minutes.
It recovered on its own at 15:30Z when the throttle cleared.

The flip metric is a minor contributor (~24 POSTs/day at the 6h TTL, plus ~64/day for the 30-minute
today clock). **The 288 is the lever.** Note the constraint on any fix: per-period server-side windows
are required — you cannot collapse the three POSTs into one and bucket rows client-side (see Lessons #2).

### 2. Snapshot build (~7 min) is longer than its cache TTL (5 min)
`serve.ps1` caches today's snapshot for 5 minutes (`$TODAY_TTL`), but a full build of today's snapshot
measured **441s and 325s** on 2026-08-11. It is therefore stale the moment it finishes, so **every fresh
page load triggers a complete rebuild.** Combined with #3 this makes local verification painful. Nobody
has decided whether to lengthen the TTL, shorten the build, or both.

### 3. `serve.ps1` is single-threaded and dies on long requests
The `HttpListener` loop serves one request at a time, so while a snapshot is rebuilding the server
cannot serve the HTML at all — a browser just hangs. Worse, it **died outright twice** on 2026-08-11
during multi-minute requests (`curl` returned HTTP 000 after ~125s while the process stayed alive but
stopped responding; it had to be killed by PID). Do not rely on the server for verification — use the
offline method in Lessons #3.

### 4. OneDrive and Git fighting over the project folder
*(Reported by the owner; not reproduced in-session.)* The project lives under
`OneDrive - Sierra Cools LV\Desktop\st-dashboard`. OneDrive sync and Git operations contend over the
same files, which has produced bulk-delete prompts. Two consequences worth knowing: the folder also
holds `secrets.json` (gitignored, but it syncs to the cloud from here), and heavy Git operations in a
synced folder are a known source of file-lock and phantom-change trouble. Moving the repo outside
OneDrive would fix both; that has not been decided.

### 5. The Worker still needs a deploy
Covered above. The committed `worker.js` rejects out-of-range goals with HTTP 400 and knows the
key→kind table. The deployed one does neither.

### 6. Orphaned goal keys in KV, with no delete route
Live KV as of 2026-08-11:
```json
{"plumbing-rev-mtd":20000000,"silo-flip-mtd":30000000,"hvac-sales-mtd":43000000,"silo-flip-ytd":30000000}
```
**Every stored key is dead.** The three `*-mtd` keys were orphaned by `538a4c4` (MTD→YTD rename);
`silo-flip-ytd` was orphaned by `8a7ca47` (goal bar removed). Meanwhile every key the dashboard actually
reads is unset — so no goal bar currently shows a target.

**They cannot be deleted through the API.** The Worker exposes only `GET /goals` and `POST /goals`, and
POST merges `{key, value}` requiring a finite number `> 0`. There is no delete route, and validation now
rejects zeroing them out. Cleanup means editing the KV entry in the Cloudflare dashboard, or adding a
delete path to `worker.js`.

---

## OPEN DECISIONS

1. **Add a delete route to the Worker?** Needed to clear the four orphaned keys (#6). Small change —
   a `DELETE /goals?key=` or a `POST` branch accepting `null` — but it is a new write path on a
   password-gated public endpoint, so it deserves a deliberate yes/no.
2. **Report `643271680` — business unit selection unconfirmed.** Carried over from the owner's notes.
   **Nothing in this repo references this report id** (grepped 2026-08-11: zero hits in any `.md`,
   `.ps1`, `.json` or `.html`), so no session context survives about which metric it feeds or which
   business units are in question. A fresh session must ask the owner rather than guess.
3. Whether to move the repo out of OneDrive (#4).
4. Whether to lengthen the snapshot TTL or shorten the build (#2).
5. From `DECISIONS.md` M6.4, still open: which membership types count as HVAC.

---

## GOALS NOT SET

**Four**, not three — `silo-rev-ytd` was added on 2026-08-11 and also has no value:

- `plumbing-rev-ytd` — Plumbing revenue, YTD (money, 0–$100M)
- `hvac-sales-ytd` — HVAC Sales sold, YTD (money, 0–$100M)
- `silo-rev-ytd` — SILO revenue, YTD (money, 0–$100M)
- `calls-booked-today` — Calls booked today (count, 0–10,000)

All four render "+ Set goal" until set, and **no pace tick or badge appears without a goal**. Set them
by clicking a bar on the dashboard (password-gated). The flip rate no longer has a goal key — its target
comes from `config.json` → `siloFlip.targetRate`.

---

## LESSONS FROM TODAY — carry these forward

### 1. `dashboard.html` must stay ASCII + HTML entities. No exceptions.
`serve.ps1` reads it with PS 5.1 `Get-Content -Raw`, which decodes a **BOM-less UTF-8** file as ANSI and
turns every multi-byte character into two. A literal `·` rendered on the wall display as `Â·`. Use
`&middot;`, `&mdash;`, `&#9650;`. Guard before committing:
```bash
git diff -U0 -- dashboard.html | grep '^+' | grep -cP '[^\x00-\x7F]'   # must print 0
```
**The same trap bites PowerShell round-trips of that file.** Reading it with `Get-Content -Raw` and
writing it back with `WriteAllBytes` double-encoded every existing em dash in one go. Use the editing
tools, or read/write bytes explicitly with `UTF8Encoding($false)`. Note line 14 already carries
pre-existing mojibake from an earlier round-trip — it is in git HEAD, not something you introduced.

### 2. Never parse report-row dates client-side.
This broke the SILO metric **twice**. PS 5.1 preserves the report's offset; pwsh7-on-Linux (the CI
runner) normalises to UTC — so rows shift across the day boundary and the number silently changes
between your machine and CI. Always use per-period **server-side** `From`/`To` windows and count the
rows the server returns. This is why today's flip figure costs its own 2 POSTs instead of being sliced
out of the MTD pull, and why the silo-revenue POST volume (#1) is hard to reduce.
Corollary: if you want an out-of-window tripwire, compare **ISO string prefixes**, not parsed dates — a
`[datetime]::Parse`-based guard re-creates the very bug it is meant to catch and false-fails on CI.

### 3. Verify offline. Do not rely on `serve.ps1`.
`build-static.ps1` needs **no network**. The reliable loop:
```bash
powershell -NoProfile -ExecutionPolicy Bypass -File build-static.ps1 -OutDir site_goaltest -NoGate
# post-process ONLY the copy in site_goaltest/ (site_*/ is gitignored), then:
chrome --headless=new --allow-file-access-from-files --hide-scrollbars \
       --window-size=1920,1180 --screenshot=out.png "file:///.../site_goaltest/index.html"
```
Notes that cost time:
- **`--window-size=1920,1080` gives `innerHeight` of 980**, not 1080 — headless chrome subtracts ~100px.
  Use `1920,1180` for a true 1080 viewport, or you are measuring the wrong height.
- **`--dump-dom` hangs** whenever the page has a pending fetch. It only works when nothing is in flight.
  `--screenshot` is more robust.
- Put test scaffolding in the **gitignored static copy**, never in the source file, so there is nothing
  to forget to revert.
- Generate cache fixtures by calling the **real** builder function (`New-SiloFlipBlock`) rather than
  hand-writing JSON — otherwise you are testing the page against a contract that may not exist.

### 4. A pre-commit hook owns `data/`.
`.githooks` refuses commits touching `data/` — the scheduled workflow commits the heartbeat and frozen
snapshots itself, and manual commits there cause merge conflicts. Unstage and commit code only. Do not
`--no-verify`. Consequence: a `final:false` cache like `data/silo-flip.json` is staged **by name** in
the workflow, because the generic `"final": true` filter would skip it and each CI run is a fresh
checkout — without that the TTL gate would never find a cache.

### 5. The 15-minute heartbeat means the remote moves constantly.
Expect `git push` to be rejected. `git pull --rebase` refuses while you have unstaged changes, so:
stash only the files that are genuinely not yours, rebase, push, pop, and **verify by checksum** that
they came back. Also: incoming commits that add a file you hold as untracked will block the rebase —
move it aside first.
When comparing a stash to the working tree, normalise line endings (`tr -d '\r'`) before concluding the
contents differ: git blobs store LF, the working tree is CRLF, so the checksums differ for a file that
is actually identical.

### 6. Fail loud, but scope the failure.
Two bugs caught by thinking about blast radius rather than by testing:
- A cached **error** counted as "fresh", so one transient 429 would have pinned a visible error on the
  wall for the full 6-hour TTL with nothing retrying it. Fixed with a separate error cooldown.
- Retrying that error on **every** run was worse — the retry itself kept the tenant throttled. The fix
  is a middle clock, not either extreme.
- A flip failure could blank the whole SILO section, taking healthy revenue figures with it. Independent
  data sources need independent failure: `safeSiloFlipCards()` contains a throw so the revenue figures
  and their goal bar survive.

### 7. Small display details that read as bugs on a wall
- A delta rounding to zero rendered **"BEHIND -0%"**. Derive the state from the **already-rounded**
  magnitude so the word and the number can never disagree; add a neutral ON PACE state.
- Two identical "How this is calculated" toggles stacked in one column with no way to tell them apart.
- Never rely on colour alone — pair it with a word and a glyph (▲/▼). The wall is read from across a
  room, and colour vision is not assumed.
