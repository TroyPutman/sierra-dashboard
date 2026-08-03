# HANDOFF-CURRENT.md

**Written 2026-08-03.** For the next session picking this up cold.

**Read order:** this file → `DECISIONS.md` (every business rule + why) → `WHERE-WE-ARE.md` (project status).
`SPEC.md` is the build spec and is now reconciled for M2/M3/M4. `API-COVERAGE.md` has a known error (below).

**Who's who:** Oliver is a PM intern with very limited coding experience — explain in plain English, write
the code for him. Troy Putman is the GM; the dashboard is for his morning meeting, on a wall screen read
from across the room.

---

## 1. Read this before touching anything

Six things that will cost you hours if you don't know them.

### 1.1 NEVER page this tenant's API at pageSize=300
The payroll endpoint returns **byte-identical duplicate rows across page boundaries at exactly 300**.
200 and 2500 are clean. This silently inflated every overtime figure by ~28–39% for weeks. Repeated
identical pulls returned the same total row count but different row *sets*, with overtime counts swinging
between 619 and 1,360.

It is a server-side defect, not our paging code. The shared pager `Invoke-StPaged` defaults to **200 (safe)**;
only the overtime metric passes an explicit size, now **2500**. If you add a metric, don't pass 300.

### 1.2 Zero overtime on Fridays and Saturdays is CORRECT
The payroll workweek **starts Friday** (Troy confirmed). Nobody has crossed the weekly hours threshold on
days one and two, so no overtime accrues. A Saturday or Sunday morning meeting legitimately shows zero.
**Do not "fix" this.** It was investigated at length and looked like a bug for a long time.

### 1.3 A past day's cancellation count keeps rising, by design
Cancellations are dated to the day the work was **booked for**, not the day someone cancelled. So late
cancellations file backwards onto closed days forever. Troy verified 19 for 2026-07-15 on 07-16; a pull on
07-29 returned 28. **Fully explained, no bug** — see DECISIONS.md. The metric now carries an on-screen
"not final, can still rise" caveat. **Do not chase the 19 — it does not reproduce and is not a target.**

### 1.4 Several API parameters are accepted and silently ignored
Confirmed in this tenant: business-unit filters on jobs; `startedOnOrAfter` and `paidTimeType` on payroll;
`payoutBusinessUnitName` and `grossPayItemType` on payroll; date filters on the cancel-log export.
They return HTTP 200 and simply don't filter. **Always verify returned records actually honour the filter.**

### 1.5 Staff catalogs default to active-only
`settings/technicians` and `settings/employees` return only active people unless you also pull
`active=false`. About 24% of employee IDs won't resolve if you forget. This already bit the SILO metric.

### 1.6 Changing a metric leaves stale cached days serving the OLD definition
Past days are cached to `data/<date>.json` and marked final. After changing any metric's math, those files
keep serving the old numbers indefinitely. Clear or move them. Eight were moved this session for exactly
this reason.

### 1.7 How to restart the dashboard server (after any code change)
**This one is for anyone, not just a coder.** The wall display is run by a program (`serve.ps1`) that reads
the calculation code (`lib/metrics.ps1`, `lib/st-common.ps1`) into memory **once, when it starts**. If a
developer changes that code, the wall screen keeps showing the OLD numbers until the server is stopped and
started again — there is no "auto-reload." If you were told "I changed the code, please restart the
server," follow these steps exactly.

1. **Stop the server that's currently running.** Find the PowerShell (black/blue terminal) window that has
   been running the dashboard — it usually has text in it about listening on a port. Click into that window
   and press `Ctrl+C`. If that doesn't work, just close the window entirely (click the X).

2. **Open a new PowerShell window.** (Start menu → type "PowerShell" → press Enter.)

3. **Go to the project folder.** Paste this exactly and press Enter:
   ```
   cd C:\Users\TroyP\Downloads\st-dashboard
   ```

4. **Start the server.** Paste this exactly and press Enter — this is the real wall-display port (8787):
   ```
   powershell -NoProfile -ExecutionPolicy Bypass -File serve.ps1 -Port 8787
   ```
   (Note: `.claude/launch.json` uses a *different* port, 8791, for a developer browser-preview helper — that
   is not the port the wall display uses. Always use 8787 for the real display unless someone explicitly
   changes it.)

5. **Confirm it worked.**
   - Wait until the PowerShell window prints a message saying it's listening (don't close the window — leave
     it running; closing it stops the server again).
   - Go to the browser tab showing the dashboard and refresh the page (F5).
   - Look at the on-screen "server started" stamp on the dashboard. It should show the **current time**, and
     there should be **no "STALE" warning**. If the stamp still shows an old time or a stale warning, the
     restart did not take effect — go back to step 1 and make sure the old window is really closed before
     starting a new one.

---

## 2. What was completed this session

### Corrections — these changed real numbers

| Metric | Before | After | Why |
|---|---|---|---|
| **Overtime**, 2026-07-15 | 529.9 hrs | **380.9 hrs** | Page-size fix (300→2500) stops duplicate rows from being returned. −28% |
| **Cancellations**, 2026-07-15 | 28 | **17** | +2 undercount fix, −13 admin cleanup. −39% |
| **Maintenances 14d**, 2026-08-03 | 531 | **413** | Window now starts tomorrow. −22% |
| **Booking sources**, "Other" | 411 (69.5%) | **35 (5.9%)** | Category-based grouping |
| **Calls per tech**, 2026-07-15 | 73 / 31 / 2.4 | 73 / 31 / 2.4 | Rule corrected; nothing to remove |

**Every overtime number in any older document or email is inflated by roughly a third.**

### Builds and rewrites
- **M2 Cancellations** — rebuilt to six locked rules (reschedules excluded, one job = one cancellation,
  administrative-cleanup reasons excluded, counted as-of-now with a caveat, counts even when the visit reads
  "Done", multi-day jobs count once on their first booked day).
- **M3 Calls per tech** — denominator is now the primary technician only.
- **M4 Overtime** — page size fixed. Feature work still pending.
- **M5 Maintenances** — window starts tomorrow.
- **M7 Call board** — weekends marked non-budgeted, never rendered as dashed "holes".
- **M8 Booking by source** — grouped by campaign *category*, so new campaigns are picked up automatically.
  Added Costco, SEO, Main Line Number, Google PPC, Texting, Outbound, Google Business Profile.
- **Two standalone scripts fixed** — `get-overtime.ps1` and `probe-overtime-lag.ps1` both paged at 300 and
  were inflating. Both now 2500; `get-overtime.ps1` verified to agree with the dashboard to 0.1 hr.

### UI
- The old **Demand tab was split into Call Board and Sources** — it overflowed 1080p once sources grew to 13.
  Both now measure **zero overflow** at 1920×1080. Source table renders in two columns.

### Investigations (findings only, no code changed)
- **Why 2026-07-15 moved 19→28** — fully explained, arithmetic closes with no residual.
- **Yelp** — it is running fine (152 calls, 66 jobs in 90 days, continuing). Avoca books those jobs directly
  without creating a lead, and the metric reads leads only. **Probably not Yelp-specific.**
- **"Problem fixed itself"** — the largest cancellation reason at 38.2%, and largely a catch-all. Full
  analysis with the per-person table is in DECISIONS.md.
- **Dispatch/arrival feasibility** — proven. Timestamps exist and are 100% populated on completed jobs.

### Documentation
`DECISIONS.md` created (new file, business-rule record). `WHERE-WE-ARE.md` updated with this session and a
rewritten open-items list. `SPEC.md` reconciled for M2/M3/M4 plus its frozen-day conventions.
`CLAUDE.md` gained the DECISIONS.md doc role and the page-size rule.

### Files changed
`lib/metrics.ps1` · `dashboard.html` · `get-overtime.ps1` · `probe-overtime-lag.ps1` ·
`SPEC.md` · `WHERE-WE-ARE.md` · `CLAUDE.md` · `DECISIONS.md` (new) · this file.
**`lib/st-common.ps1`, `serve.ps1` and `config.json` were NOT touched.**

---

## 3. Build queue, in priority order

All definitions are locked — see DECISIONS.md for the reasoning. None of these is blocked on a decision
unless marked.

**1. Overtime features** — highest priority because one part is a correctness gap.
   - Show all overtime AND **job-only** overtime side by side. The current figure includes idle, driving and
     training, which makes it far larger than "overtime spent on calls". Troy wants both.
   - Show **dollars** as well as hours.
   - **Say when payroll is incomplete.** The two most recent days carry roughly *half* the payroll entries of
     older days, and this metric reports *yesterday* — so it systematically reads the least-complete day.
     It must say so rather than silently showing a low number. This is a fail-loud violation today.

**2. Overview 3-day maintenance calendar** — small, quick, and Troy asked for it directly. He wants the
   Maintenances panel to show the next 3 days as a small calendar so he can work the schedule with the
   scheduler.

**3. Club members per house** — a correctness fix. A member is a **house/location**, not a customer. Today a
   customer with two properties counts once, so if one property ran its maintenance they vanish from the
   list entirely, understating the backlog. **Partly blocked** — see §4.
   Also: the season flips cooling→heating **the last week of September, with no hard cut** — leftover cooling
   members must keep showing after the flip.

**4. Dispatch and arrival** — a new metric, fully specified, feasibility already proven.
   - Clock starts at **dispatch**, not when the tech leaves. **Sitting-around time counts, deliberately** —
     Troy wants to see it. Do not "improve" this by excluding it.
   - On time = first call of the morning, arriving before 8:30 AM when dispatched before 8:30.
   - Time to first call measured from first dispatch.
   - **Must use nearest-pair-per-visit matching, not first-of-each-type.** The events live on a per-*job* log
     but the timings belong to individual *visits*; naive pairing produced gaps of 81 and 213 hours in
     testing. This will silently poison any average if built the lazy way.
   - Cost: one API call per completed job, roughly 100/day for the service units.

**5. SILO roster and definition**
   - Derive the roster **per month** — it changes. Alex Yakovchuk shows 1 call in June against 303 across the
     year because he stepped up to help manage during the busy season. A fixed list is wrong every month.
   - Adopt John's definition: a "call ran" = a **completed job carrying the ROPP tag**. No tag, or a tag
     management removed, does not count. This should close most of the ~290-call gap over six months.
   - A tech who left mid-month still appears, with a partial number.
   - Current baseline under the OLD definition: June 2026 = 831 calls / 400 TGLs / 48.1%. **Expect this to
     move.**

**6. Running totals (day/month/year to date)** — not built at all. Anchoring is decided: a past date shows
   totals **as of that day**, not up to now. The calls-per-tech period denominator is also decided: the
   **typical number working per day** (average of daily headcounts), not every tech who worked at any point.

**7. Backdating / live past days** — **needs a design decision first, see §4.**

---

## 4. Blocked on Oliver

1. **Which membership types count as HVAC.** How they're identified today is a **guess**, and it sets the
   size of the entire member base (currently 9,633 active members, 1,998 left to run). **Action: pull every
   membership type with its active member count and have Troy identify which are HVAC. Do not guess.**
   Blocks the club-members metric being trustworthy.

2. **The always-on machine for the wall display.** Still running on a personal laptop. Troy confirmed the
   display should be **always on**, which makes a dedicated machine with verified auto-start on boot a hard
   requirement, not a nice-to-have. `SETUP-ON-NEW-PC.md` covers installing it; picking and standing up the
   host is open. **This blocks real use.**

3. **How to reconcile live past days with dashboard speed.** Troy decided a backdated entry *should* change a
   closed day. That contradicts the current freeze-and-cache design and has **not** been built. What breaks:
   past days are instant today and recomputing costs minutes on a cold pull (club members is the slow part),
   which a polling wall display can't afford; and Troy may act on a morning number that differs by afternoon.
   Recommended direction is to keep caching but re-check past days on a schedule and show when each number
   was last computed — **not** to delete the freeze logic. Needs Oliver to pick an approach.

4. **Whether other campaigns besides Yelp bypass lead creation.** Not checked. If they do, the booking-source
   metric may need rebuilding on jobs rather than leads. Investigable without him, but the decision to
   rebuild is his. Troy's instruction was: note it, don't change the logic yet.

5. **"Problem fixed itself" final call.** Left counted, provisionally. It's 38.2% of all cancellations and
   roughly 1 use in 10 matches the label. The recommendation on file is to leave it counted and fix the
   dropdown instead — there's no plain "Customer cancelled / will reschedule" option, and a quarter of the
   notes say exactly that. Revisit if Sierra adds one.

6. **Troy has not eyeballed any of the new numbers.** M2, M3, M4 and M5 all changed on 2026-08-03. M6 and M7
   have never been human-verified at all.

---

## 5. Known issues flagged but not fixed

- **Three tabs overflow a 1080p screen.** Cancellations is bad — roughly the bottom 40% is off-screen
  (~766px). SILO ~150px, Pipeline ~44px. All pre-existing. Cancellations is the one to fix first; its detail
  table was capped at 16 rows to fit, but the summary rankings and filter row added later pushed it over.
- **`API-COVERAGE.md` is wrong** — it states the actual arrival timestamp is not available and would need
  GPS. It **is** available, on a per-job event log. That error steered the project away from a buildable
  metric for weeks. Correct it.
- **Call count drift, not investigated.** 2026-07-15 read booked 249 in the docs and 232 on a live pull —
  about −7%. Completed was stable. Nobody has chased this.
- **The booking-source metric is blind to Avoca-booked jobs** (see Yelp, above). It reports zero for a
  channel Sierra actively pays for.
- **The payroll-lag probe has no baseline.** Its old one was captured with the broken page size and was moved
  out, so `ot-probe/` is empty and the next run starts a clean baseline. That's intended.
- **Cancellations got ~2.5s/day slower** — it now fetches job records for everything on the board that day,
  which is the only way to catch a cancelled job whose visit reads "Done".
- **A bulk cancellation-history export exists** (~31,500 records in ~7 calls) and is not being used by the
  metric, which still fetches per job. Worth adopting if the metric needs to get faster.

---

## 6. Things that look like bugs but aren't

Beyond §1, these will each cost a fresh session time:

- **The calls-per-tech change moved nothing, and that's correct.** Only 1 job in 99 had a second technician
  assigned, and that person was already the primary on another call. **The "ride-alongs inflate this"
  premise did not hold in the data.** 2.4 calls per HVAC tech was already right. Don't go looking for the
  missing change.
- **The maintenance calendar's first cell is tomorrow, not today.** Deliberate, as of 2026-08-03.
- **The maintenance total dropped 22% on 2026-08-03.** Intended. Bookings fall off steeply as you look
  further out — Aug 4 had 101 visits, Aug 5 had 67, Aug 6 had 38 — so dropping a fully-booked today and
  adding a near-empty day fourteen out is a big swing. That gap *is* the dead space the metric exists to show.
- **Cancellation records are never deactivated** — all ~31,500 are still marked active. So a job that was
  cancelled, reinstated and then completed still carries an active cancellation record. This is why the
  metric requires the job to be *currently* cancelled as well; nine jobs that **completed** on 2026-07-15
  would otherwise have counted as cancellations.
- **The forward-looking metrics ignore the date picker.** Maintenances, club members, call board and booking
  sources are all "as of pull time" and return the same values whatever date is selected. By design, noted
  on screen.
- **Two ports.** Manual runs use **8787**; the browser-preview helper in `.claude/launch.json` uses **8791**.
  Same app.
- **The server must be restarted to pick up math-layer changes** — `lib/metrics.ps1` is loaded at startup.
  `dashboard.html` is served fresh per request and needs only a browser reload.
- **Verify by calling metric functions directly** from a scratchpad script that dot-sources the libs. Going
  through the server writes cache files and makes past-day comparisons confusing.

---

## 7. Reference numbers for verification

Use these to confirm nothing regressed. All computed 2026-08-03 unless noted.

| Metric | Date | Value |
|---|---|---|
| Call count | 2026-07-15 | booked 232 / completed 229 *(docs say 249/228 — stale)* |
| Cancellations | 2026-07-15 | **17** |
| Cancellations | 2026-07-29 | 25, later 29 *(rises by design)* |
| Calls per tech | 2026-07-15 | HVAC-Svc 73/31/2.4 · Plumbing-Svc 26/13/2.0 |
| Overtime | 2026-07-15 | **380.9 hrs** (HVAC-Svc 250.9, Plumbing-Svc 130.0) |
| Maintenances 14d | 2026-08-03 | **413** (window Aug 4 → Aug 17) |
| Club members | 2026-08-03 | 9,633 active / 7,635 ran / **1,998 left to run** |
| Booking sources | 30 days | 591 leads, "Other" **35** |
| SILO | June 2026 | 831 calls / 400 TGLs / 48.1% *(old definition)* |

---

## 8. Working files from this session

Backups live in the session scratchpad:
`C:\Users\TroyP\AppData\Local\Temp\claude\C--Users-TroyP-Downloads-st-dashboard\7328bb34-f5f5-4de3-b1f1-33dc6fc26262\scratchpad\`
containing `stale-cache-backup\` (8 moved day files), `baseline\` (pre-change metric captures), and
`ot-probe-stale-baseline\`.

> ⚠️ **That scratchpad is session-scoped temporary storage and may not survive.** Nothing there is required
> to run the dashboard — the cached day files simply regenerate on demand — but if you need the pre-change
> baselines and they're gone, recompute them from live data rather than assuming they still exist.
