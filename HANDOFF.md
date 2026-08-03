# Sierra Morning Dashboard — Architecture & Planning Handoff

> Paste-ready brief for a SEPARATE Claude (Projects) chat to help PLAN / ARCHITECT this codebase.
> Snapshot date: **2026-08-03**. Distinct from `HANDOFF-CURRENT.md` (the in-repo "what to do next").
> Source of truth order in the repo: `DECISIONS.md` (business rules) > `SPEC.md` (build spec, stale for M2/M3/M4) ; `WHERE-WE-ARE.md` = status ; `API-COVERAGE.md` = API capability (has a known error, see §3).

---

## 1. Project overview

**What it is**
- A morning wall-display dashboard for Sierra Air Conditioning & Plumbing (Las Vegas).
- Purpose: GM (Troy Putman) runs a daily morning meeting; the dashboard replaces clicking through many ServiceTitan reports.
- Shows **raw numbers only** — no targets, no pass/fail, no red/green. Troy judges the numbers himself.
- Big text, readable across a room; minimal interaction (a date picker + tab bar). Always-on, auto-refreshing.
- Data source: **ServiceTitan API** (tenant `1066404518`). Avoca is a later phase (blocked — Enterprise-tier only).

**Tech stack**
| Layer | File(s) | Role |
|---|---|---|
| Data | `lib/st-common.ps1` | Auth, paging (`Invoke-StPaged`), timezone, shared catalogs (job types, users, cancel reasons, tech→BU, campaigns), `Get-DashConfig`. No metric logic. |
| Math | `lib/metrics.ps1` | One `Get-Metric-*` fn per metric + `$METRIC_DEFS` registry; `Build-Snapshot` assembles all with per-metric timestamps + error isolation. |
| Presentation | `serve.ps1` + `dashboard.html` | PowerShell `HttpListener` server + single static HTML/JS page. |
- Front end: vanilla HTML/JS, Sierra light theme, Poppins font, logo inlined as base64. Server serves the one HTML file.
- No build system, no npm, no framework. PowerShell is built into Windows. **Not a git repo** — history is via file timestamps + these docs.

**Key architectural decisions (do not violate)**
- **Strict three-layer separation.** Adding a metric = one `Get-Metric-*` fn + one `$METRIC_DEFS` entry + one tab render. Never blur data/math/presentation.
- **Pacific → UTC day boundaries.** All day buckets are `America/Los_Angeles`, converted to a UTC range for API filters. Never bucket by raw UTC date. (Exception discovered: payroll `gross-pay-items` buckets by a plain calendar `date` at UTC midnight, not the Pacific window.)
- **Fail loud, never guess.** A failed/missing metric shows "COULD NOT LOAD" on screen — never a stale or made-up number. A real zero must look different from an error.
- **No hard-coded targets.** Raw numbers only; any future targets read from `config.json` at runtime (`Get-DashConfig`).
- **Freeze-and-cache past days.** Past day → `data/<date>.json`, served instantly only if `final` (computed after that Pacific day ended). A mid-day partial is never served as final — it is recomputed and re-frozen. Today recomputes when its cache is older than a TTL (`$TODAY_TTL = 300s`). SILO months cache similarly (`$SILO_CUR_TTL = 21600s / 6h`).
- **CRITICAL API guardrail — NEVER page this tenant at `pageSize=300`.** The payroll endpoint returns byte-identical duplicate rows across page boundaries at *exactly* 300 (200 and 2500 are clean). This is a **page-size defect**, not our paging code — **there is NO row-dedup logic**; the fix is the page size (overtime now pages at 2500). It silently inflated every overtime figure ~28–39% for weeks. `Invoke-StPaged` defaults to 200 (safe).
- **Verify every filter param actually took effect.** This tenant returns HTTP 200 and silently ignores several filters (BU filter on jobs; date/pay-type filters on payroll; date on the cancel-log export).
- **Ports:** real wall-display server default **8787** (`serve.ps1`); browser-preview dev helper **8791** (`.claude/launch.json`). Same app.
- **Server dot-sources code ONCE at startup — no hot-reload.** After any change to `serve.ps1` / `lib/*.ps1` the server must be restarted. `dashboard.html` is served fresh per request (browser reload only). `GET /api/version` + a header stamp warn "STALE CODE" when on-disk code is newer than what the running server loaded.

**Server routes** (`serve.ps1`)
- `GET /` (or `/index.html`, `/dashboard.html`) → the page
- `GET /api/metrics?date=YYYY-MM-DD` → daily snapshot JSON (all $METRIC_DEFS)
- `GET /api/silo?month=YYYY-MM` → SILO/ROPP monthly (separate cache, off the daily path)
- `GET /api/version` → `{ serverStart, loadedCodeMtime, currentCodeMtime, stale }`

---

## 2. Current state — metrics & tabs

**Metrics** (registry = `$METRIC_DEFS` in `lib/metrics.ps1`; SILO is a separate `/api/silo` endpoint, deliberately off the daily snapshot). Note: code numbers M1–M9; the new dispatch metric is labeled **M10** here for reference but is not formally numbered in code.

| # | Metric (id) | Measures | Status | Human-verified by Troy? |
|---|---|---|---|---|
| M1 | Call Count (`call-counts`) | Booked + completed new-opportunity jobs per BU (10 units) | BUILT, definition settled | Definition yes; a booked-count −7% drift uninvestigated |
| M2 | Cancellations (`cancellations`) | Cancelled jobs dated to day booked-for; 6 locked rules | BUILT (rebuilt 08-03) | **No** — numbers changed 08-03 |
| M3 | Calls per Tech (`calls-per-tech`) | Completed calls ÷ primary techs, Service BUs (333/353) | BUILT (denominator changed 08-03, no numeric effect) | **No** |
| M4 | Overtime (`overtime`) | OT clock hours, Service; now all-hours AND job-only side by side | BUILT + enhanced 08-03 | **No** |
| M5 | Maintenances 14d (`maint-14d`) | Maintenance visits booked next 14 days (window starts tomorrow) | BUILT | Yes (total, 2026-07-24) |
| M6 | Club Members Left to Run (`club-members`) | Active HVAC members with no cooling maintenance in 16 mo | BUILT | **No** (+ HVAC-type definition is a guess — blocking) |
| M7 | Call Board (`call-board`) | 14-day calendar of booked calls per day, Service BUs | BUILT | **No** |
| M8 | Booking Rate by Source (`booking-source`) | Leads booked ÷ total by campaign category, 30 days | BUILT (rebuilt 08-03) | **No** (+ Avoca-books-without-lead blind spot) |
| M9 | SILO / ROPP (`silo-ropp`, `/api/silo`) | Monthly ROPP calls / TGLs / conversion per roster tech | BUILT | Mechanically verified June 2026; definition set to change |
| M10 | Dispatch & Arrival (`dispatch-arrival`) | Avg dispatch→arrival mins; on-time % of first call before 8:30 | **BUILT NEW 08-03** | **No** (dev-verified; tech-identity bug caught & fixed) |

**Dashboard tabs** (8, in `dashboard.html` `TABS`): Overview · Calls · Cancellations · Staffing · Pipeline · Call Board · Sources · SILO.
- Overview = curated headline numbers, no tables. Detail tabs grouped by morning-meeting flow.
- Staffing hosts M3 + M4 + **M10** (new). Pipeline hosts M5 + M6. Call Board = M7, Sources = M8 (Demand tab was split into these two so it stops overflowing 1080p).
- SILO uses a month picker (header swaps controls per tab); dark analytical module inside the light app.

**Business-unit map** (10 active): HVAC = 337 Install-AOR, 342817560 Maintenance, 370 Sales(NR), 340802904 Sales-Costco(NR), 333 Service · Plumbing = 595105985 Drains, 408662213 Install, 354 Maintenance, 353 Service · (208554530 Inventory excluded).

---

## 3. Recent changes this session (2026-08-03)

File timestamps confirm today's edits: `config.json` (08:48), `.claude/agents/*.md` (08:59), `lib/metrics.ps1` (09:44), `HANDOFF-CURRENT.md` (09:58), `serve.ps1` (09:59), `dashboard.html` (09:59). Earlier today: `DECISIONS.md`, `SPEC.md`, `WHERE-WE-ARE.md`, `CLAUDE.md`, `get-overtime.ps1`, `probe-overtime-lag.ps1`.

**M4 Overtime — enhanced**
- Now shows **all-hours OT AND job-only OT side by side**. Job-only = payroll rows with `jobId != 0`; **includes travel-to-job time**, labeled "on jobs (incl. travel)".
- Added **incomplete-payroll warnings**: (a) workweek-in-progress (payroll week = Fri→Thu); (b) partial-day detection — day's pay-item count vs median of same weekday over prior N weeks. Threshold + lookback live in `config.json`: `payrollCompletenessThreshold` (0.80), `payrollCompletenessLookbackWeeks` (4).
- **Dollars intentionally NOT built** — ST payroll gross-pay-items returns `amount=0` and has no rate/wage field. OT dollars need an external per-tech pay-rate source (pending from payroll). Not a bug; a data limitation.
- July 15 all-hours OT unchanged at **380.9** after the change.

**M10 Dispatch & Arrival — NEW metric**
- Source: `GET /jpm/v2/tenant/{tenant}/jobs/{id}/history` events ('Technician Dispatched' / 'Technician Arrived'; 'Technician Dispatch Canceled' dropped).
- **Pairing: chronological LIFO nearest-following-arrival per job** (naive first-of-type pairing gave 81–213h gaps — avoided).
- **Tech identity = the job's PRIMARY technician** via appointment-assignments (earliest active assignment — same rule as M3), via a shared `Get-JobPrimaryTechMap` extracted from M3. **NOT** the dispatch event's `employeeId` (that is the office dispatcher, ~7 people — using it was a bug caught during verification and fixed). M3 output verified unchanged by the refactor.
- Outputs: avg dispatch→arrival minutes; on-time % (per tech's first call of day; denominator = techs dispatched before 8:30 Pacific, numerator = those arrived before 8:30; shown as "N of M"); anomalies (unmatched dispatch/arrival, unresolvable primary tech) surfaced, not dropped; in-progress warning like M4.
- Scope: service units only (333 HVAC-Service, 353 Plumbing-Service). Cost ~1 API call per completed service job (~100/day). Lives on the Staffing tab.

**Code-version / staleness stamp**
- `serve.ps1` records server-start time + loaded-code mtime at startup; `GET /api/version` returns `{ serverStart, loadedCodeMtime, currentCodeMtime, stale }`; `dashboard.html` shows a header stamp and a prominent "STALE CODE — restart the server" badge when on-disk code is newer than the running server's. Restart steps added to `HANDOFF-CURRENT.md` §1.7 (real port 8787).

**Agent governance**
- `.claude/agents/worker.md` and `judgment-worker.md` gained an ABSOLUTE no-delete rule (move to `archive/`, ask first) after a worker deleted cached day-snapshots without authorization. The 4 caches (2026-07-15/28/29, 08-03) were rebuilt and verified (7/15 back to 380.9 OT / 17 cancellations exactly).

**Doc wording**
- The overtime issue is now recorded as a **page-size defect** (not a "duplicate-rows / dedup fix") — one misleading cell in `HANDOFF-CURRENT.md` corrected.

**⚠ Divergences from older repo docs — reconcile these**
- **`API-COVERAGE.md` is WRONG on arrival timestamps** (item 8 says the actual arrival time is not exposed / needs GPS). It **is** available via job history and is 100% populated on completed jobs. That error steered the project away from M10 for weeks. Correct it.
- **`SPEC.md` is stale for M2/M3/M4** — still the pre-2026-08-03 definitions. Where it disagrees with `DECISIONS.md`, DECISIONS.md wins.
- **Older overtime numbers in `WHERE-WE-ARE.md` (and any older doc/email) are inflated ~28–39%** (pre page-size fix). E.g. 2026-07-15 was 529.9, now 380.9.
- **`DECISIONS.md` and `WHERE-WE-ARE.md` still list M4-features and Dispatch/Arrival as "DECIDED — NOT BUILT."** Both are now BUILT this session — those status lines are stale.
- **`HANDOFF-CURRENT.md` build queue still lists "Overtime features" and "Dispatch and arrival" as to-build**, and its §2 says `serve.ps1`/`config.json` "were NOT touched" — true of the earlier wave only; both were edited later today (version stamp; payrollCompleteness keys). Treat HANDOFF-CURRENT as slightly behind the very latest work.
- **`config.json` is no longer "unused"** (WHERE-WE-ARE says so) — M4 now reads `payrollCompletenessThreshold` / `...LookbackWeeks` from it.
- M2's old "verified 19 for 2026-07-15" no longer reproduces (rises by design → now 17 on-the-day / higher later). Not a bug.

---

## 4. In-progress / half-finished / known bugs / open questions

**Open decisions pending (this session)**
- **Staffing tab VERTICAL OVERFLOW (unresolved).** M10's per-tech detail table (~44 rows on a busy day) makes Staffing ~2841px tall vs a 1080p wall display (no horizontal overflow). Trim options considered: qualifying techs only / headline-only on wall / fixed-height scroll box / leave full. **Needs a call.**
- **OT dollars — blocked** pending per-tech pay rates from payroll (ServiceTitan has none).

**Pre-existing blockers / open questions**
- **Which membership types count as HVAC (M6) — BLOCKING.** Currently a guess; it sizes the whole member base (9,633 active / 1,998 left to run). Action: pull every membership type with active counts, have Troy identify HVAC. Do not guess.
- **Avoca integration — blocked** (Enterprise tier only; Sierra not on Enterprise). Not actionable until Avoca enables it.
- **M8 blind spot:** Avoca books some jobs without creating a lead (proven via Yelp — 152 calls / 66 jobs / 0 leads since 2026-03-03). Not checked whether other campaigns do the same; if they do, M8 may need rebuilding on jobs not leads. Instruction: note it, don't change logic yet.
- **"Problem fixed itself" cancellation reason — provisional.** 38.2% of cancellations, largely a catch-all (~1 in 10 matches the label). Left counted; revisit if Sierra adds a "Customer cancelled / will reschedule" reason.
- **Live-past-days vs freeze/cache — design decision open.** Troy decided a backdated entry SHOULD change a closed day; that contradicts the current freeze-and-cache design. Recommended: keep caching but re-check on a schedule and show last-computed time — **do NOT delete the freeze logic**. Breaks: speed (cold pull = minutes, M6 slow), consistency (morning number changes by afternoon), "verified" numbers stop reproducing.
- **Wall-display host machine — open, blocks real use.** Still on a personal laptop; Troy wants always-on → needs a dedicated machine with verified auto-start on boot. `SETUP-ON-NEW-PC.md` covers install; picking/standing up the host is open.
- **Human verification outstanding:** M2/M3/M4 numbers changed 08-03 and Troy hasn't eyeballed them; M6 and M7 never human-verified; M8 rebuilt, unverified; M10 new, dev-verified only.

**Known UI/data issues flagged, not fixed**
- Cancellations tab overflows 1080p by ~766px (bottom ~40% off-screen); SILO ~150px; Pipeline ~44px; plus the new Staffing overflow above.
- Call-count booked drift on 2026-07-15 (docs 249 vs live 232, ~−7%) uninvestigated.
- Cancellations metric ~2.5s/day slower (fetches job records to catch cancelled jobs whose visit reads "Done"). A bulk cancel-history export exists (~31,500 rows / ~7 calls) but isn't used yet.

---

## 5. Next steps

**Build queue (definitions locked; not blocked unless noted)**
1. **M6 club members per house** — a member is a house/location, not a customer (partly blocked by HVAC-type question). Season flips cooling→heating last week of Sept, no hard cut (leftover cooling members keep showing).
2. **Overview 3-day maintenance calendar** — small; Troy asked directly (next 3 days as a mini calendar to work the schedule).
3. **M5 window** — confirm starts tomorrow (built) and holds.
4. **M7 weekends** — mark weekends non-budgeted so light volume reads as expected, not a dashed "hole".
5. **M9 SILO** — derive roster per month (it changes); adopt John's definition (a "call ran" = completed job carrying the ROPP tag; removed tag doesn't count); a tech who left mid-month still appears with a partial number. Expect June baseline (831 / 400 / 48.1%) to move.
6. **Running totals (DTD/MTD/YTD)** — not built. Anchoring decided: a past date shows totals as of that day. M3 period denominator = typical number working per day (avg of daily headcounts).
7. **Trim the Staffing tab** for the wall (resolve the M10 overflow).

**Blocked / needs a human first**
- HVAC membership-type list (Troy) → unblocks M6 accuracy.
- OT dollars (per-tech pay rates from payroll) → unblocks M4 dollars.
- Live-past-days vs freeze design decision (Troy/Oliver).
- Wall-display host machine + auto-start (deployment).
- 3-day call board fill % would need a per-tech capacity constant from config (no API field) — currently shows booked + techs-scheduled, no fill %.

**Reference numbers for regression checks** (all 2026-08-03 unless noted): Cancellations 2026-07-15 = **17** · Calls/tech 2026-07-15 HVAC-Svc 73/31/2.4, Plmb-Svc 26/13/2.0 · Overtime 2026-07-15 = **380.9h** (HVAC 250.9 / Plmb 130.0) · Maintenances 14d = **413** (Aug 4→17) · Club members 9,633 / 7,635 ran / **1,998 left** · Booking sources 30d = 591 leads, Other 35 · SILO June 2026 = 831 / 400 / 48.1% (old definition).

**Credentials:** `secrets.json` (clientId, clientSecret, appKey, tenantId) exists at project root, is gitignored, and must never be committed, emailed, or pasted. Its values are not reproduced anywhere in the docs.
