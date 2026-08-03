# SPEC.md — Metric spec for the Sierra Morning Dashboard

**What this is:** the build spec for every metric marked **POSSIBLE** in API-COVERAGE.md.
It defines, for each number on the wall, exactly what it means, where it comes from, and
how it's computed — precisely enough to build from. **No code here. No API calls were made
to write this.** Field lists come from the 2026-07-15 read-only probe recorded in API-COVERAGE.md.

**Authoritative rule record:** for the *reasoning* behind any business rule below — who decided it, why,
what it did to the numbers, and what's still open — see **DECISIONS.md**. This file (SPEC.md) is the build
spec (what to compute and how); DECISIONS.md is the record of why. If the two ever disagree, DECISIONS.md
wins and this file should be corrected.

**Ground rules (from Oliver / Troy):**
- Raw numbers only. No targets, no pass/fail, no color judgment.
- Date picker: **today updates live** (recomputed each refresh, climbs through the day).
  **Past days are NOT reliably frozen** — see "Live vs frozen" below. This was assumed until 2026-08-03
  and proved false; do not build anything that depends on a finished day's number staying put.
- Every metric is reported **per business unit, separately** — the 9 trade units below.
  **Inventory (208554530) is excluded** from all metrics.
- Fail loud: if a call errors or returns non-200, that metric shows an explicit error on
  screen. A real zero must look different from "no data / error." Never show a stale or
  guessed number.

Metrics specified here: **Call count, Cancellations, Calls per tech, Overtime, Maintenances
booked next 14 days, Club members left to run, 3-Day Call Board, Booking Rate by Source.**

---

## Shared conventions (read this first — it applies to every metric below)

### The 9 reported business units
| ID | Name | Trade |
|---|---|---|
| 333 | HVAC - Service | HVAC |
| 337 | HVAC - Install - AOR | HVAC |
| 342817560 | HVAC - Maintenance | HVAC |
| 370 | HVAC - Sales (NR) | HVAC |
| 340802904 | HVAC - Sales Costco (NR) | HVAC |
| 353 | Plumbing - Service | Plumbing |
| 354 | Plumbing - Maintenance | Plumbing |
| 408662213 | Plumbing - Install | Plumbing |
| 595105985 | Plumbing - Drains | Plumbing |

`208554530 Inventory` is **never** queried or shown as a metric row.

### Time zone — the single most important convention
Every ServiceTitan timestamp (`completedOn`, `modifiedOn`, `start`, `date`, …) is **UTC**.
Sierra runs on **America/Los_Angeles** (Pacific — PDT/UTC-7 in summer, PST/UTC-8 in winter).

**A "day" always means a calendar day in Pacific time.** To get "a day," compute Pacific
midnight → next Pacific midnight, then convert *that* to a UTC range for the API filter.
Never bucket by the raw UTC date: a job completed 10:00 PM Pacific is 05:00 AM the *next*
day in UTC and would land on the wrong day. This applies to **every date-bucketed metric.**

### Live vs frozen — CORRECTED 2026-08-03, read this before trusting any past day
- **Today** (the current Pacific day): recomputed on every refresh; the number grows through the day.
- **Past day**: the dashboard currently caches it and marks it "final", but **a past day's underlying data
  genuinely keeps changing.** Proven, not theoretical: 2026-07-15 showed 19 cancellations when the GM
  verified it on 2026-07-16 and 28 on 2026-07-29. Eleven cancellations were recorded *after* he looked, and
  they file back onto 07-15 because a cancellation is dated to the day the work was **booked for**, not the
  day it was cancelled. See DECISIONS.md, "The two corrections that matter most".
- **Troy's decision (2026-08-03):** a backdated entry SHOULD change a closed day. This is **not yet built**
  and it conflicts with the current freeze-and-cache design. What breaks: recomputing past days on demand
  costs minutes on a cold pull (club members is the slow part) which a polling wall display cannot afford;
  and a number Troy acted on in the morning may differ by the afternoon. Recommended direction is to keep
  caching but re-check past days on a schedule and show when each number was last computed — **not** to
  delete the freeze logic outright.
- **Any metric that can move after its day ends must say so on screen** (M2 already does). A stale number
  presented as final breaks the fail-loud rule just as much as a made-up one.
- The date picker chooses which Pacific day is "the selected day."

### How counts are obtained (applies to all count metrics)
ServiceTitan list endpoints return a page of records, plus a `totalCount` **only when asked**
(an `includeTotal`-style flag — confirm exact parameter at build; in the probe only
`telecom/calls` returned a total by default). Rule: either request the total explicitly, or
**page through every page** (`hasMore`/`page`) and count — never trust a single page as the total.

### Running totals — defined once (Pacific time, anchored to the SELECTED day)
For accumulating (past-looking) metrics, all three are "as of the selected day":
- **Day-to-date (DTD):** selected day's Pacific midnight → now (if the selected day is today)
  or → that day's end (if it's a frozen past day). For a frozen day, DTD = the full-day total.
- **Month-to-date (MTD):** Pacific midnight on the 1st of the selected day's month → end of the selected day (inclusive).
- **Year-to-date (YTD):** Pacific midnight on Jan 1 of the selected day's year → end of the selected day (inclusive).

Two metrics below are **not** accumulating (Maintenances next 14 days is forward-looking;
Club members left to run is a backlog snapshot) — each says how running totals apply to it.

---

## M1 — Call count (per business unit)

**Plain English:** for each business unit, **two** new-opportunity call counts on the selected day:
- **Booked** — how many qualifying calls are *scheduled FOR* that day (on the dispatch board that day),
  regardless of when the call was created. (CORRECTED 2026-07-16 — see booked-date note.)
- **Completed** — how many qualifying calls were *run/finished* that day.

Both use the **same** new-opportunity filter (below). They count different cohorts of jobs, so they
are not expected to match on any given day (see the timing edge case). ("Did we hit our call count yesterday?")

**Definition of a "call" (CLOSED — from Oliver's boss's existing working implementation against
this same tenant):** a job counts as a call (a **new opportunity**) only if, judged on the **JOB
record** (not the appointment), **all three** are true:
- `recallForId` is empty, **AND**
- `warrantyId` is empty, **AND**
- the **job type name** does **not** match the pattern `recall | warranty | part…install`
  (i.e. the name doesn't contain "recall", "warranty", or "part" followed by "install"), matched
  case-insensitively.

A job failing any one of these is a recall/warranty/parts-install follow-up, not a new opportunity,
and is excluded from the call count.

**Note on business units:** the boss's *call board* also drops the Install unit (408662213) because
it doesn't count installs. **Our dashboard does NOT do that** — Troy wants all trade units reported,
so Install stays in. We adopt only the field-level opportunity filter above, not his BU exclusion.

**Endpoints:** `jpm/v2/.../jobs` and `jpm/v2/.../appointments` (booked/scheduled side), plus
`jpm/v2/.../job-types` to resolve the job type **name** the filter needs (job-types is in the **jpm**
namespace, NOT settings; verified live 2026-07-16).
**Fields used:** jobs → `businessUnitId`, `jobStatus`, `completedOn` (buckets the **completed** count),
`id`, **`recallForId`**, **`warrantyId`**, **`jobTypeId`** (→ name via job-types).
appointments → `start` (buckets the **booked/scheduled** count), `status`, `jobId`.

**The new-opportunity filter (used for BOTH counts):** keep a job only if `recallForId` is empty
**and** `warrantyId` is empty **and** its job type name does not match `recall|warranty|part.*install`
(case-insensitive). Resolve `jobTypeId` → name via job-types.

**Calculation — COMPLETED count, step by step:**
1. From the selected date, build the Pacific-day window and convert to a UTC start/end.
2. Query jobs with `completedOn` within that window, `jobStatus = Completed`, business unit in the
   9 trade IDs (Install 408662213 **included**).
3. Apply the new-opportunity filter.
4. Page through all results (don't stop at page 1). Group surviving jobs by `businessUnitId` and count.

**Calculation — BOOKED (scheduled-for-the-day) count, step by step:**
1. Same Pacific-day → UTC window.
2. Query `jpm/v2/.../appointments` with `start` in that window (`startsOnOrAfter`/`startsBefore`); page through all.
3. Keep appointments whose `status` is NOT `Canceled` (a canceled appointment is not "on the board" — it's
   in the cancel tray, which is M2). NB: the appointment `active` flag is NOT reliable here — a Canceled
   appointment can still have `active=true` (verified live 2026-07-16); filter on `status`, not `active`.
4. Collect the distinct `jobId`s of those appointments.
5. Batch-fetch those jobs via `jpm/v2/.../jobs?ids=` (in chunks). Every requested id MUST come back, or FAIL LOUD.
6. Keep jobs whose `businessUnitId` is one of the 9 trade IDs AND that pass the new-opportunity filter.
7. Count DISTINCT qualifying jobs per `businessUnitId`. A job with two appointments the same day is still one call.

Inventory (208554530) is excluded from both by never including its ID.

**Booked-date note (CORRECTED 2026-07-16 — Troy):** "Booked" means **scheduled FOR the day** (the calls
on the dispatch board that day), NOT booked-on (`createdOn`). It is bucketed by the appointment `start`.
This is what Troy means by the day's call count. Closes OQ #11's booked-basis question.

**Breakdown:** grouped by `businessUnitId` → 9 rows, each showing both a booked and a completed count.

**DTD / MTD / YTD:** both counts widen the same way — booked over the period (by appointment `start`),
completed over the period (by `completedOn`), day / month-to-selected-day / year-to-selected-day (per
Shared conventions), grouped by unit.

**Edge cases & handling:**
- *Scheduled one day, completed another (the key timing case):* a call scheduled for Monday but completed
  Wednesday (or a Monday completion of a call that was scheduled earlier) lands in different days for booked
  vs completed. So for any single day the two numbers count **different jobs** and will not reconcile; a call
  scheduled and completed the same day appears in both. Present them as two distinct numbers, never as if one
  should equal the other, and never subtract one from the other to imply a backlog.
- *Canceled appointments:* excluded from booked via `status != Canceled` (they belong to the M2 cancel tray).
- *Multi-appointment jobs:* a job scheduled twice in one day is counted once (distinct jobs), consistent with completed.
- *Day boundary / time zone:* a job completed (or booked) near midnight — bucket by Pacific day (see conventions).
- *One job, many appointments:* still **one call** (count jobs, not appointments/visits).
- *Backdated completions:* a job with `completedOn` = yesterday but entered today makes a "frozen"
  day drift slightly. Handling: recompute recent past days each refresh and label the screen "as of
  last refresh" so it's never presented as more precise than it is.
- *Re-opened / re-completed jobs:* rely on **current** `jobStatus` + `completedOn`, not history.
- *Job type name required:* the opportunity filter matches on the job type **name**, not its ID, so
  the job-types list must be loaded and cached to resolve `jobTypeId` → name. If a job's type can't be
  resolved, don't silently keep or drop it — flag it (fail loud) rather than miscount.
- *Filter is field-level, not BU-level:* the recall/warranty/parts-install exclusion is applied per job.
  It is independent of the business-unit breakdown — every one of the 9 units gets the same filter.
- *True zero vs error:* 0 qualifying jobs is a real "0"; a failed call is an error state — show them differently.

---

## M2 — Cancellations (per business unit)

> **Rewritten wholesale 2026-08-03** — the previous definition (appointment-status based, one row per
> cancelled *visit*, "verified 19" for 2026-07-15) is gone. See DECISIONS.md M2.1–M2.7 for the full
> reasoning, the evidence behind each rule, and the "problem fixed itself" reason-code investigation
> (not repeated here — this file is build spec, not analysis).

**Plain English:** a cancellation for the selected Pacific day is a **JOB** — not a visit — that (a) had at
least one appointment scheduled in that Pacific day, (b) is genuinely cancelled as of right now (job status
`Canceled` **and** carries an active cancel-log entry — either alone is not enough, see below), (c) counts
**once per job** no matter how many of its visits were touched, (d) is **not** an administrative
record-cleanup (see the exclusion list below), and (e) counts **regardless of whether that day's appointment
itself reads Canceled or Done** — the job is what got cancelled, the visit's leftover status doesn't matter.
A multi-day job counts **once only, on the first Pacific day it ever had a visit booked** — never on a later
day, even if that's the day the cancellation happened to land.

**Why job status is required, not just the cancel-log:** this tenant **never deactivates a cancel-log
entry** — 31,553 of 31,553 sampled entries are `active`. So a stale cancel-log entry survives forever on a
job even after it's reinstated and actually run. Nine jobs that **completed** on 2026-07-15 still carried an
active cancel-log entry from an earlier, later-reversed cancellation. Reading the cancel-log alone would
wrongly count those nine as cancellations. Requiring current `jobStatus = Canceled` **in addition to** the
log entry rules that out.

**Why the first-day anchor uses ALL of the job's appointments, regardless of status:** if the anchor were
computed only from appointments that are still live (not cancelled), it would **drift between pulls** —
each time an earlier visit on a multi-day job gets cancelled, "the earliest surviving appointment" would
change, moving the job to a different day on a later pull. Anchoring on every appointment the job has ever
had, cancelled or not, fixes the anchor day permanently.

**Endpoints & how each piece is sourced:**
- Candidate days → every appointment scheduled in the Pacific day, **any status** (Done visits must be
  included — see rule (e)). `jpm/v2/.../appointments`, `start` in the Pacific window.
- Job status / type / unit → batch-fetch the jobs on those appointments. `jpm/v2/.../jobs?ids=` →
  `jobStatus`, `businessUnitId`, `jobTypeId`.
- Genuinely-cancelled check + reason / time / who → `jpm/v2/.../jobs/{id}/canceled-log`, filtered to
  `active` entries, latest by `createdOn` → `reasonId`, `createdOn` (cancel time), `createdById` (user).
- First-booked-day anchor → **all** appointments on the job (`jpm/v2/.../appointments?jobId=`), any status —
  take the earliest `start`.
- Reason name → `jpm/v2/.../job-cancel-reasons`. User name → `settings/v2/.../employees/{id}`. Job type name
  → `jpm/v2/.../job-types`.

**Calculation, step by step:**
1. Build the Pacific-day window (UTC range) for the selected day.
2. Query appointments with `start` in the window, **any status**. Page through all. Group by `jobId`.
3. Batch-fetch every one of those jobs (`jobs?ids=`). Keep only the 9 trade business units.
4. For each job: if `jobStatus` is not `Canceled`, it's a reschedule, not a cancellation — **not counted**
   (rule (b)/M2.1).
5. Otherwise, pull the job's cancel-log; keep the latest **active** entry. If there is no active entry, the
   job cannot be told apart from a reschedule — **not counted**, but flagged as a caveat (should be rare;
   near-zero in practice).
6. If the entry's `reasonId` is on the administrative-exclusion list (below), **exclude it from the count —
   but still show it on screen**, tallied separately, never silently dropped (rule (d)/M2.3).
7. Otherwise, pull **all** appointments on the job (any status), find the earliest `start`, convert to its
   Pacific day. If that day is not the selected day, this job belongs to an **earlier** day and is excluded
   here (it was already counted there) — rule (f)/M2.6.
8. If it survives all of the above: count the job **once**, under its `businessUnitId`, regardless of how
   many of its appointments that day were cancelled (rule (c)/M2.2). Emit one detail row (job type,
   scheduled time, cancel time, reason, who cancelled it).

**Administrative-exclusion reason list (by ID — names get re-typed, IDs don't):**

| ID | Reason |
|---|---|
| 102 | Duplicate entry |
| 656703594 | Avoca Duplicate |
| 403340016 | History call clean up (legacy — 0 uses currently, kept for old-day consistency) |
| 398228702 | Reschedule (legacy — a reschedule is never a cancellation on D1 grounds anyway) |

This is a business-rule list, not math — **it could reasonably move to config.json** so it can be edited
without touching code. Every exclusion must be **counted and displayed** (a running tally + the reason mix),
never dropped silently — that's what makes the exclusion auditable.

**Breakdown:** grouped by `businessUnitId` → 9 rows, plus a per-cancellation detail list (business unit, job
type, scheduled time, cancelled-at, reason, who).

**DTD / MTD / YTD:** same logic, widened window (candidate day = the first-booked Pacific day, which must
fall within the period), grouped by unit.

**Edge cases & handling:**
- **Not final, and it is on screen:** this count is **as of the moment of the pull**, not frozen once a day
  is in the past. Cancellations recorded after the fact still file back onto the day the work was originally
  scheduled for, so **a past day's count can rise indefinitely** — there is no such thing as "the final
  number" for a past day. The dashboard must carry an explicit on-screen caveat saying so; never present a
  past day's cancellation count as settled.
- **Reference numbers:** 2026-07-15 = **17** under this definition (was 28 under the pre-2026-08-03 rule).
  Do **not** treat "verified 19" (an older manual count) as a reproduction target — it does not reproduce
  under either the old or the new rule, and is explained (not contradicted) in DECISIONS.md's "two
  corrections" section. Do not use it to sanity-check a rebuild.
- *No active cancel-log entry on a `Canceled` job:* cannot be distinguished from a reschedule with a stale
  status; excluded from the count, flagged as a caveat rather than silently dropped or silently counted.
- *Job status flips back and forth over time:* only the **current** `jobStatus` matters — history is not
  consulted beyond the cancel-log's own `active` flag.
- *Multiple cancelled visits on one job:* still one cancellation (rule (c)).
- *Time zone:* every day boundary (candidate day and first-booked day) is bucketed by Pacific day, same
  rule as everything else.

---

## M3 — Calls per tech (per business unit)

> **Denominator rule rewritten 2026-08-03** — the denominator now counts only the PRIMARY technician per
> job, not every assigned body. See DECISIONS.md M3.1–M3.2 for the reasoning and the (honest) finding that
> this changed nothing in practice.

**Plain English:** on the selected day, the average number of completed calls per **working** technician,
where "working" means the tech who actually **ran** the call — helpers, apprentices, and ride-alongs sent
along on the same job must not count toward the headcount. Numerator is unchanged: completed jobs ÷ primary
techs who ran ≥1 job.

**SCOPE (DECIDED 2026-07-16 — Troy):** this metric is ONLY for **HVAC - Service (333)** and
**Plumbing - Service (353)**, reported as two separate rows. Installers, sales, maintenance, and drains
units are NOT included. So both the completed-jobs numerator and the tech denominator are restricted to
those two Service units.

**Who counts as the primary technician (DECIDED 2026-08-03):** there is **no primary/lead flag** in the
data — an `appointment-assignment` record carries `technicianId`, `assignedById`, `assignedOn`, `status`,
`active`, but nothing that marks one assignee as "the" tech and another as a helper. So primary is defined
operationally: for each job, the primary is the **active** assignment with the **earliest `assignedOn`**;
ties are broken by **lowest `technicianId`**, so the result is reproducible run to run rather than
depending on hash-map ordering. Only that one technician per job counts toward the denominator.

**Endpoints:** `jpm/v2/.../jobs` (completed jobs, as M1) + `dispatch/v2/.../appointment-assignments`
(to attribute each job to its primary technician) + `settings/v2/.../technicians` (names, optional).
**Fields used:** jobs → `id`, `businessUnitId`, `jobStatus`, `completedOn`;
appointment-assignments → `jobId`, `technicianId`, `assignedOn`, `status`, `active`.

**Calculation, step by step:**
1. Get the day's completed jobs per unit (exactly as M1), restricted to the two Service units.
2. For each job, read `appointment-assignments` filtered on `jobId`; keep only `active = true` assignments
   with a non-empty `technicianId`.
3. If no active assignment exists on a job, it contributes to the numerator but not the denominator (should
   not normally happen on a completed job).
4. Otherwise pick the **primary**: sort by `assignedOn` ascending, then by `technicianId` ascending; take
   the first. That is the one technician credited for the job.
5. **Numerator** = number of completed calls (distinct jobs) in the unit that day.
6. **Denominator** = number of *distinct primary* `technicianId`s across the unit's completed jobs that day.
7. Calls per tech = numerator ÷ denominator, rounded to 1 decimal.

**Breakdown:** two rows only — HVAC - Service (333) and Plumbing - Service (353), computed independently.

**DTD / MTD / YTD:** numerator = completed jobs over the period, same as today. **Period denominator is
DECIDED but NOT YET BUILT (DECISIONS.md M3.2):** it must be the **average of daily headcounts** over the
period — "the typical number of primary techs working per day" — **not** every distinct primary tech seen
at any point across the whole period. Counting every tech who appeared once in a month would inflate the
denominator with people who barely worked and understate productivity. Do not build MTD/YTD for this
metric using a simple distinct-tech-over-the-period denominator; use the daily-average rule instead.

**Edge cases & handling:**
- *No techs completed a job (denominator 0):* show "—" / "no calls," never `0` and never a divide-by-zero error.
- *One job, two techs (helper/ride-along):* the job is still **one call**, and now only the **primary**
  (earliest-assigned, tie-broken by lowest technician ID) counts toward the denominator — the helper does
  not add a head. **In practice this changed nothing measurable:** on 2026-07-15, only 1 of 99 completed
  Service-unit jobs had a second technician assigned at all, and that tech was already primary on another
  call that day. The "ride-alongs are inflating this number" premise did not hold — 73 calls / 31 techs /
  2.4 was already correct before and after this rule. Still implemented, because it's now correct on
  principle and will matter on days where doubling-up is more common.
- *Which roles are "techs":* scoped to the two Service units (333, 353); within those units, the primary
  rule above is what keeps helpers/apprentices out of the headcount.
- *Time zone:* Pacific-day rule.

---

## M4 — Overtime (per business unit)

> **Paging fix landed 2026-08-03; several other features are DECIDED but NOT YET BUILT** — see the
> "STILL TO BUILD" list below and DECISIONS.md M4.1–M4.5.

**Plain English:** overtime hours worked, for the day before (yesterday).

**SCOPE (DECIDED 2026-07-16 — Troy):** the day before ONLY (yesterday) — no live "today" number, so payroll
processing lag is acceptable (we always look back a day). Restricted to **HVAC - Service (333)** and
**Plumbing - Service (353)** techs (by payout unit). **SPLIT BY ACTIVITY TYPE** — a separate line per
activity (Idle, Driving, Training, job/wrench time, etc.), per Service unit, plus a total. Troy wants the
breakdown, not one lump number. Activity comes from the gross-pay-item `activity` field; report whatever
activity values actually appear in the data (do not hard-code the list).

**Endpoint:** `payroll/v2/tenant/1066404518/gross-pay-items`
**Fields used:** `paidDurationHours` (hours), `paidTimeType` (to isolate overtime — the only value observed
is `'Overtime'`; there is no separate double-time value), `date` / `startedOn` (which work day),
`businessUnitName` (per unit), `employeeId`, `employeeType`.

**MANDATORY paging rule — page at `pageSize=2500`, never anything smaller:** at `pageSize=300` this
tenant's payroll endpoint returns **byte-identical duplicate rows across page boundaries** — a server-side
defect, not a paging bug in our code. The same day, pulled repeatedly at page size 300, returned the same
`totalCount` but a different mix of rows each time, and overtime totals swung between 619 and 1,360 hours
run to run — roughly **28–39% inflated**, and not even consistently so. Page sizes 200 and 2500 both return
**zero** duplicates. A single work day's rows fit in one page at 2500 (the API's own cap is 5000), so 2500
is the standard page size for this endpoint. **Never page this endpoint at 300, or at any size below what
fits a day in one page.**

**Calculation, step by step:**
1. Build the Pacific-day window for "yesterday" relative to the selected day.
2. Query `gross-pay-items` in that date range, with `pageSize=2500` (see the paging rule above).
3. Keep only rows whose `paidTimeType = 'Overtime'`.
4. Sum `paidDurationHours`, grouped by `businessUnitName` and by `activity`.
5. Map each `businessUnitName` to one of the two Service unit IDs (333, 353) for display.

**Breakdown:** activity type (rows) x the two Service units (columns), plus a per-unit total and a grand total.

**Reference number:** 2026-07-15 total service-unit overtime = **380.9 hours** (HVAC-Service 250.9,
Plumbing-Service 130.0) at the corrected `pageSize=2500`. Any overtime figure computed before the paging fix,
or quoted from an older document or email, is inflated and should not be trusted.

**DTD / MTD / YTD:** widen the date window; sum overtime hours over the period, grouped by unit. Same
`pageSize=2500` rule applies to every page of every day in the widened window.

**Edge cases & handling:**
- *Payroll lag:* accepted by design — we only ever report the day before, by which point payroll has
  mostly (not necessarily fully) posted — see the incomplete-payroll warning below.
- **Zero overtime on Friday/Saturday is CORRECT, not a bug:** the payroll workweek starts on **Friday**
  (confirmed by Troy). Overtime is a *weekly* threshold, so nobody has crossed it yet on days 1–2 of the pay
  week — Friday and Saturday will legitimately show **zero** overtime and climb through the week from there.
  A Saturday-or-Sunday-morning dashboard reading zero overtime is expected behavior, not something to
  investigate as a data problem.
- *Double-time:* moot — no separate double-time `paidTimeType` value exists in this tenant's data;
  `'Overtime'` is the only overtime value.
- *Business unit is a name string here, not an ID* — map `businessUnitName` to unit id; verify the two
  Service names match exactly. Restricting to 333/353 means only those two mappings need to be right.
- *Which date field* (`date` vs `startedOn`) represents the work day — confirm at build.

**STILL TO BUILD (decided, not yet implemented — do not assume these exist):**
- **All-overtime vs job-only overtime, shown side by side.** The current figure includes idle time, driving
  time, and training time along with wrench time, which makes it much larger than "overtime actually spent
  running calls." Troy wants both numbers visible at once, not a single blended figure.
- **Dollars in addition to hours.** Hours only today; a dollar figure needs to be added alongside.
- **An incomplete-payroll warning.** Payroll entry lags behind the work day — how much depends on how busy
  the office is — and the two most recent days consistently carry roughly **half** the payroll entries of
  older, fully-settled days. Because M4 reports **yesterday**, it is systematically reading the day that is
  *least* likely to be fully entered. The dashboard must detect this and say **"payroll may be incomplete"**
  rather than silently displaying a low overtime number that looks final but isn't — this is a fail-loud
  requirement, not a nice-to-have.

---

## M5 — Maintenances booked next 14 days (per business unit)

**Plain English:** how many maintenance visits are **booked on the calendar** over the next 14 days.
Purpose: see the **dead space to fill**. ("Currently 50 or less.")

**SCOPE (DECIDED 2026-07-16 — Troy):** count what's actually BOOKED ON THE CALENDAR — i.e. maintenance
**appointments** scheduled in the next 14 days — NOT membership obligations. Membership status is irrelevant.
Anchor the 14-day window from **today**. Count VISITS (appointments). Use ALL maintenance job types, but
**organize the output SECTION BY SECTION** (not one lump number) so Troy can react and tell us what he means.
Semi-Annual Tune-ups are INCLUDED as their own section.

**SECTIONS (natural groupings of the maintenance job types, from the live list 2026-07-16):**
1. SAM Cooling (HVAC cooling maintenance) — `^SAM Cooling Service`
2. SAM Heating (HVAC heating maintenance) — `^SAM Heating Service`
3. HVAC Semi-Annual Tune-ups — `^Semi Annual Tune-up`
4. Filter Changes — `^Filter Change`
5. Plumbing Water Heater Maintenance (SAM) — `^Plumbing SAM .*Water Heater Service`
6. Plumbing Water Heater Tune-ups — `Water Heater Tune-up`
7. Commercial Maintenance — `^Commercial Cooling/Heating Maintenance`
A job type falls into the FIRST matching section; anything not matching any section is not "maintenance"
(repair/"Issue"/Install/Estimate types are excluded). The script prints the matched job types per section
so the grouping is transparent and easy to revise. This resolves OQ #5 (source = appointments; visits; sectioned).

**Endpoint:** `jpm/v2/.../appointments` joined to `jpm/v2/.../jobs`; alternative source
`memberships/v2/.../recurring-service-events`.
**Fields used:** appointments → `start`, `jobId`, `status`, `active`; jobs → `jobTypeId`, `businessUnitId`;
plus a job-types reference (`jpm/v2/.../job-types` — jpm namespace, NOT settings) to know which `jobTypeId` counts as maintenance.

**Calculation, step by step:**
1. Window = today (Pacific) 00:00 → +14 days.
2. Query appointments with `start` in that window; keep `status != Canceled`.
3. Collect distinct jobIds; batch-fetch jobs (`jobs?ids=`) for `jobTypeId` and `businessUnitId`.
4. Keep appointments whose job type is a MAINTENANCE type (list from the job-types investigation).
5. Count VISITS (appointments), broken out by day (to show dead space) and by trade (HVAC vs Plumbing).

**Breakdown:** primary = by SECTION (14-day totals per section, in the order above, + grand total). Secondary =
one row per day for the next 14 days (HVAC / Plumbing / Total) so dead space still shows as low daily counts.

**DTD / MTD / YTD:** **Not applicable.** This is a forward-looking snapshot of the next 14 days, not an
accumulating past total. The dashboard shows the current count only. (Say this on screen so its absence
of running totals isn't read as an error.)

**Edge cases & handling:**
- *"Maintenance" job types* — taken from the job-types investigation (2026-07-16). Confirm the exact set with Troy.
- *Always anchored from today* (live pipeline metric), regardless of any date picker.
- *Count VISITS (appointments)* — a job with two maintenance visits in the window counts twice (two calendar slots).
- *Canceled appointments* — excluded via `status != Canceled` (same rule as M1 booked).
- *Reschedules* moving in/out of the window are handled naturally by the snapshot.

---

## M6 — Club members left to run (per business unit)

**Plain English:** how many club members are **overdue to run their cooling maintenance** — i.e. active
members who have NOT had a cooling maintenance in the last 16 months. Backlog number. ("Only run 10–20% in June/July.")

**SCOPE (DECIDED 2026-07-16 — Troy):** HVAC only for now (Plumbing added later). "Left to run" = active
member has no **completed cooling maintenance** within the last **16 months**. In the fall this switches
from cooling to heating maintenance.
**DESIGN REQUIREMENT:** season (cooling/heating), lookback months (16), and trade (HVAC) must be **config
values**, so the fall switch to heating is a config edit, NOT a code rewrite. Build a config file for these.
This resolves OQ #6's definition.
**UNBLOCKED / BUILT (2026-07-16 — Troy):** Cooling maintenance = job types matching `^SAM Cooling Service`;
heating = `^SAM Heating Service`. Season is CONFIG (Cooling now; flip to Heating in the fall = one-line change),
lookback = 16 months, trade = HVAC only. Semi-Annual Tune-ups / Commercial / Plumbing are NOT part of M6 (M6 is
specifically the cooling-vs-heating club obligation; general maintenance sits in M5).

**Approach (completion-based set difference):** rather than trusting recurring-service-event statuses, we
define "left to run" directly from Troy's words — an active HVAC member with NO **completed** cooling
maintenance in the last 16 months.

**Endpoints & fields:**
- Member base → `memberships/v2/.../memberships` (active), with `membershipTypeId`, `businessUnitId`, `customerId`.
  HVAC membership identification uses the membership-type / business-unit (see the membership investigation).
- "Ran cooling recently" → `jpm/v2/.../jobs` with `jobStatus = Completed`, `completedOnOrAfter` = today − 16 months,
  filtered to cooling job types (`^SAM Cooling Service` via `jobTypeId` → name). Take the distinct `customerId`s.
- `jpm/v2/.../job-types` for the cooling name match.

**Calculation, step by step:**
1. CONFIG: `season` = Cooling → job-type pattern `^SAM Cooling Service`; `lookbackMonths` = 16; `trade` = HVAC.
2. Pull active HVAC memberships → member base (distinct customerId).
3. Pull completed cooling-maintenance jobs since (today − 16 months) → distinct customerId who "ran recently".
4. **Left to run = member base customers NOT in the ran-recently set.** Count them.

**Breakdown:** a single HVAC "left to run" count (+ member base and ran-recently counts for context). Plumbing later.

**DTD / MTD / YTD:** N/A — this is a backlog snapshot (how many are currently overdue), not an accumulating total.

**Edge cases & handling:**
- *Config switch to heating:* change the season config value only; pattern becomes `^SAM Heating Service`. One-line change.
- *Member identity:* matched on `customerId`. A member with multiple locations/systems is treated at customer level
  for this rough draft; location/system-level precision can come later. FLAG this to Troy.
- *HVAC membership identification* is provisional (see membership investigation) — print the member-base count so it's checkable.
- *16-month window* is measured from today (a member who ran cooling 17 months ago counts as "left to run").

---

## M7 — Call Board: booked calls per day, next 14 days (calendar)

**Plain English:** a calendar of when new-opportunity calls are on the schedule over the next 14 days, so Troy can
SEE, at a glance, which days are filling and which are still thin. (REVISED 2026-07-16 — Troy: there is no per-tech
capacity limit, so "full" / fill-% was the wrong question. Dropped it entirely. No capacity number, no config for it.)

**SCOPE (Troy 2026-07-16):** HVAC-Service (333) + Plumbing-Service (353), booked calls per day, next 14 calendar days
from today. Rendered as a calendar grid (same visual as the M5 maintenance calendar): each day a cell with the day's
total booked, the HVAC/Plumbing split, and techs-scheduled as a small secondary footnote. **Light days read as thin
dashed "holes"** = open room on the board.

**Endpoints & fields:**
- BOOKED → `jpm/v2/.../appointments` (`start`, `status`, `jobId`) + `jpm/v2/.../jobs` (`businessUnitId`, new-opp
  filter). Distinct new-opp jobs with a non-canceled appointment that day, split HVAC-Service / Plumbing-Service.
- TECHS (secondary) → `dispatch/v2/.../technician-shifts` (`start`, `technicianId`, `active`) + `settings/.../technicians`
  (`businessUnitId`). Distinct service techs scheduled that day. Shifts populated forward; `startsBefore` ignored, client-filter.

**Output:** one table [Date, HVAC-Service, Plumbing-Service, Total, Techs] x 14 days → the dashboard renders it as a
calendar (Total = big number, H/P split, "techs N" footnote; total 0 = dashed hole).

**Caveats:** techs bucketed by home unit (a tech could run another unit's calls). Always "as of now," not tied to the
selected day. NO capacity/"full" concept — capacity scope and the per-tech-capacity config were removed as the wrong question.

---

## M8 — Booking Rate by Source (last 30 days)

**Plain English:** of the leads that came in from each marketing source, what share got booked.

**SCOPE (Troy 2026-07-16):** sources Angi, Avoca, Yelp, LSA, Schedule Pro. **Booked = lead has a `bookingId`**
(the 249). Converted (became a job) shown as a secondary column. Period: last 30 days.

**Endpoints & fields:** `marketing/v2/.../campaigns` (`id`, `name`, `category.name`) + `crm/v2/.../leads`
(`campaignId`, `bookingId`, `status`). Group leads by campaign, classify to a source, count booked / total.

**Source rules (ordered):** Angi = category "Lead Aggregators" AND name~`angi`; Avoca = name~`avoca`;
Yelp = category "Yelp"; LSA = category "Google LSA"; Schedule Pro = name~`scheduler|scheduling pro`. Unmatched = Other.

**DATA QUIRK (found 2026-07-16 — flagged on screen):** `bookingId` works for Angi (99%) but reads **0% for LSA
and Avoca even though some leads Converted (>0)** — those sources apparently become jobs without a `bookingId`.
So the bookingId rate UNDERCOUNTS LSA/Avoca; Converted may be the truer "booked" signal for them. Revisit the
"booked" definition with Troy (per-source, possibly).

**AVOCA CAVEAT (on screen):** this is ST leads *attributed to Avoca campaigns* and their booked rate — NOT
Avoca's own call-answer→book funnel (that lives in Avoca, external/Enterprise-gated). Different metric; do not confuse.

---

## M9 — SILO / ROPP monthly (per-tech calls, TGLs, conversion)

**Plain English:** SILO is a sub-department of HVAC Service identified by the **ROPP tag**. This metric
tracks, per SILO technician and for the SILO team, how many **ROPP calls were run**, how many **TGLs**
(turnover-generated leads) those techs generated, and the **call→TGL conversion** — **month by month**.
Ported from a coworker's frozen example dashboard onto our live pipeline; it is defined to be **correct
against live ServiceTitan**, NOT calibrated to match that example's hardcoded numbers.

**Definitions (LOCKED 2026-07-21 — Oliver):**
- **ROPP CALL** = a JOB that ALL of: carries the ROPP tag (`tagTypeId 962027`); `businessUnitId` ∈
  {**333** HVAC-Service, **342817560** HVAC-Maintenance}; `jobStatus=Completed` with `completedOn` in the
  Pacific month; passes the **new-opportunity filter** (`recallForId` empty AND `warrantyId` empty AND
  job-type name not matching `recall|warranty|part.*install`); and was **run by a roster tech**
  (an ACTIVE `appointment-assignment`, matched on `technicianName`). **Count every job; NO customer dedupe.**
- **TGL** = a JOB whose job type is an **"Estimate … TGL"** type (7 types), **created** in the Pacific month,
  whose `jobGeneratedLeadSource.employeeId` resolves to a roster tech. (`employeeId` = the tech who turned
  over / generated the lead — NOT `soldById`, which is the salesperson who ran the estimate.)
- **CONVERSION** = TGLs ÷ calls, per tech and for the SILO total.
- **"A month"** = a Pacific (America/Los_Angeles) calendar month → UTC window. Never raw UTC.

**The 14-tech SILO roster:** Noah Weng, Joe Mendoza, Benjamin Wyllie, Nikko April, Andrew Trujillo,
Dustin Romine, Juan Tlatenchi, Brandon Moreno, Francisco Valencia, Mario Castro, Cole Pantol,
Nathan Colquitt, Robert Silinzy, Alex (Oleksiy) Yakovchuk. Matched on the **technician NAME** in the
assignment / lead record (last name + an accepted first name), NOT the technician catalog id.

**Endpoints & fields:**
- calls → `jpm/v2/.../jobs` (`tagTypeIds`, `jobStatus`, `completedOnOrAfter/Before`, `businessUnitId`,
  `recallForId`, `warrantyId`, `jobTypeId`) + `jpm/v2/.../job-types` (name) +
  `dispatch/v2/.../appointment-assignments?jobId=` (`technicianName`, `active`).
- TGLs → `jpm/v2/.../jobs` (`jobTypeId`, `createdOnOrAfter/Before`, `jobGeneratedLeadSource{employeeId,jobId}`)
  + `settings/v2/.../technicians` + `settings/v2/.../employees` for id→name, **including inactive**
  (pull `active=false` too — otherwise ~24% of generating-tech ids don't resolve and the roster undercounts).

**Calculation:**
1. Pacific month → UTC start/end.
2. Pull ROPP `Completed` jobs in the window; keep svc/maint BU + new-opp.
3. For each, read `appointment-assignments`; if any ACTIVE tech matches the roster, count the job for that
   tech. Distinct qualifying jobs = SILO calls.
4. Pull Estimate-TGL jobs created in the window; map `jobGeneratedLeadSource.employeeId` → name (incl.
   inactive) → roster; count per tech = TGLs.
5. Conversion = TGLs ÷ calls, per tech and SILO total.

**Build status:** standalone **`get-silo-ropp.ps1`** (`-Month yyyy-MM`; defaults to last full month).
Verified **June 2026: 831 calls / 400 TGLs / 48.1%** for the SILO team; runs in **~135 s / month**.
**WIRED INTO THE DASHBOARD 2026-07-21** — dark SILO tab, separate `/api/silo?month=YYYY-MM` endpoint, month picker, month-cached (past months frozen; current month refreshes at most every 6h).

**Edge cases & handling:**
- *Month by month by design:* one month ≈ ~950 job examinations + ~950 per-job assignment calls ≈ 2 min;
  a 6-month window is ~6× the calls, hence the monthly cadence.
- *`appointment-assignments` ignores a `technicianId` filter* (returns all) — attribution MUST be per-job by `jobId`.
- *Active-only catalogs:* `technicians`/`employees` default to active only; must also pull `active=false`.
- *Low per-tech months* (a tech showing ~1 call) can be legitimate (role change / partial tenure) — that's a
  **roster** question for John, not a data bug. Verify roster membership / active dates rather than "fixing" the script.
- *Not calibrated to the example dashboard:* the ~290-call difference vs the coworker's frozen numbers is
  expected and accepted; correctness is measured against live ServiceTitan.

---

## OPEN QUESTIONS (need a human decision — not guessed)

1. **What is a "call"? — CLOSED (2026-07-15).** A job counts as a call (new opportunity) only if, on the
   JOB record: `recallForId` empty AND `warrantyId` empty AND job type name does not match
   `recall|warranty|part.*install` (case-insensitive). Source: Oliver's boss's existing working
   implementation against this same tenant. Applied in M1. (His board's separate Install-BU exclusion was
   deliberately NOT adopted — Troy wants all trade units reported.)
2. **How is a cancellation dated / defined? — CLOSED (2026-08-03), superseding the 2026-07-16 answer.**
   A cancellation is now a JOB (not a visit) that had an appointment that Pacific day, is genuinely cancelled
   (job status Canceled AND an active cancel-log entry — the log alone is unreliable because this tenant never
   deactivates entries), counted once per job, excluding administrative cleanup (by reason ID), counted
   regardless of that day's appointment status, and anchored to the job's FIRST-EVER booked day. See M2 above
   and DECISIONS.md M2.1–M2.7. 2026-07-15 = 17 under this rule (was 28). The count is never final for a past
   day and carries an on-screen caveat.
3. **Calls per tech — CLOSED for the daily metric (2026-08-03).** Which techs: ONLY HVAC-Service (333) and
   Plumbing-Service (353), two rows, and within those units only the PRIMARY technician per job counts
   (earliest-assigned active assignment, ties by lowest technician ID) — helpers/ride-alongs do not inflate
   the denominator. In practice this changed nothing (only 1/99 jobs on 2026-07-15 had a second tech). STILL
   OPEN: the MTD/YTD period denominator, DECIDED as "average of daily headcounts" but NOT YET BUILT.
4. **Overtime — CLOSED (2026-08-03), superseding the 2026-07-16 answer.** Day-before only; Service techs
   (333, 353) only; SPLIT BY ACTIVITY TYPE plus total; MANDATORY pageSize=2500 (pageSize=300 returns duplicate
   rows and inflated overtime 28–39% — never use it). Payroll workweek starts Friday, so Friday/Saturday
   legitimately read zero overtime — that is correct, not a bug. 2026-07-15 = 380.9 total hours (HVAC-Service
   250.9, Plumbing-Service 130.0). Double-time is moot — no separate DoubleTime value exists in the data.
   STILL TO BUILD: all-overtime vs job-only overtime side by side, dollars alongside hours, and an
   incomplete-payroll warning (the two most recent days carry roughly half the entries of older days, and this
   metric always reports yesterday — the least-complete day).
5. **Maintenances next 14 days — CLOSED (2026-07-16).** Count maintenance APPOINTMENTS (visits) booked on the
   calendar in the next 14 days from today; NOT membership obligations. Broken out by day and trade. Depends on
   the maintenance job-type set (from the job-types investigation).
6. **Club members left to run — CLOSED (2026-07-16).** HVAC only; "left to run" = active HVAC member with no
   completed COOLING maintenance in the last 16 months. Cooling = `^SAM Cooling Service`, heating = `^SAM Heating
   Service`; season/lookback/trade are config (fall switch = one-line). Completion-based set difference. Member
   identity matched at CUSTOMER level for this rough draft (location/system precision later — flag to Troy).
7. **Inventory / "all 10" — CLOSED.** 9 trade units reported; Inventory (208554530) excluded, not shown as a row.
8. **Running-total anchoring — STILL OPEN.** Confirm MTD/YTD are "as of the selected day" (picking a past date shows
   totals as of that date) rather than always up to now. Not needed until a running-total metric is built.
9. **Frozen-day drift — STILL OPEN.** Is small drift from backdated entries acceptable (with an "as of last refresh"
   label), or should past days be locked at first computation?
10. **Time zone — CLOSED.** America/Los_Angeles, day boundaries in Pacific time. Confirmed implicitly by Troy's
    day-based answers (scheduled-for-service day, day-before, etc.).
11. **Does Oliver's boss's call board count BOOKED or COMPLETED calls? — CLOSED (2026-07-15).** His board shows BOTH
    booked and completed, same as ours (M1). No conflict between our numbers and his. (Still worth confirming at build
    time that our booked count is *booked-on* (`createdOn`) rather than *booked-for* if his uses a different basis, but
    there is no headline contradiction to resolve.)
