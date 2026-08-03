# API-COVERAGE.md — Can ServiceTitan's API feed Troy's checklist?

**What this is:** a research file only. No dashboard code was written. For every item on
Troy's checklist, it says whether the ServiceTitan API can actually provide the number,
which endpoint/fields would feed it, and — where it can't — exactly what's missing.

**How this was verified:** ServiceTitan's own doc pages are JavaScript-rendered and could
not be read directly (one mirror also returned 403). So instead of guessing, I ran a
**live read-only probe** against tenant 1066404518 on **2026-07-15**: one access token, then
a 1-record `pageSize=1` call to each endpoint below, printing only HTTP status and the
*field names* returned (never values, never credentials). Where a claim rests on docs I
couldn't read, it says so. Where it rests on the live probe, the status code is noted.

**Reminder on scope:** this dashboard shows **raw numbers** with a date picker (today = live,
past = frozen) plus day/month/year-to-date running totals. It does **not** judge numbers
against targets. Targets may be added later from a config file — nothing here blocks that.

---

## Legend

- **POSSIBLE** — the API returns what's needed; it's a matter of building it.
- **PARTIAL** — some of it is available; part is missing or needs a workaround/business rule.
- **NOT POSSIBLE** — ServiceTitan's API can't provide this (wrong system, or data not exposed).

All list endpoints confirmed returning HTTP **200** in the probe unless noted otherwise.

---

## Coverage table

| # | Checklist item | Endpoint(s) & field(s) | How it would be calculated | Verdict | If PARTIAL / NOT POSSIBLE — what's missing |
|---|---|---|---|---|---|
| 1 | **Call count yesterday, HVAC & Plumbing** | `jpm/v2 …/jobs` → `jobStatus`, `completedOn`, `businessUnitId`, `jobTypeId` (200) | Count jobs completed on the chosen day, filtered to HVAC/Plumbing business units | **POSSIBLE** | — (needs a human decision: does a "call" = a completed job? and a Business-Unit → HVAC/Plumbing mapping — see Notes) |
| 2 | **Cancellations** | `jpm/v2 …/jobs` → `jobStatus` (= Canceled); `jpm/v2 …/job-cancel-reasons` → `name` (200) | Count jobs with status Canceled on the day/BU; optionally break down by cancel reason | **POSSIBLE** | — |
| 3 | **Demand calls not booked same-day** | `crm/v2 …/leads` → `callId`, `status`, `bookingId`, `createdOn`, `followUpDate` (200); `telecom/v2 …/calls` → `type`, `leadCall` (200, `totalCount` returned) | Leads/inbound calls created on day X with no booking/job created that same day | **PARTIAL** | No single "demand call not booked" field. Requires a business definition of "demand call" and of "same-day," then joining leads↔bookings. Doable but rule-dependent, not a stock number. |
| 4 | **Reschedules** | `jpm/v2 …/appointments` → `start`, `modifiedOn`, `status` (200) | Infer from appointments whose scheduled `start` changed | **PARTIAL** | No reschedule count/event and no change history in the list endpoint. `modifiedOn` tells you *something* changed, not that it was rescheduled. Would over/under-count. |
| 5 | **Calls per tech** | `jpm/v2 …/jobs` (completed) + `dispatch/v2 …/appointment-assignments` → `technicianId` (200). Alt: Reporting API "Technician Performance" report | Completed jobs on day/BU, grouped by tech, ÷ number of techs with >0 completed | **POSSIBLE** | — (Reporting-API path is an alternative but is rate-limited; see Notes) |
| 6 | **Idle vs working time** | `payroll/v2 …/gross-pay-items` → `paidDurationHours`, `paidTimeType` (200); `dispatch/v2 …/technician-shifts` → `start`,`end` (200). Idle: ST "Idle Report" via Reporting API | Working hours from paid hours / shift length ÷ … | **PARTIAL** | **Working** time = available. **Idle** time as ST's Idle Report defines it is GPS vehicle-idle data, which these data endpoints do **not** expose. Only obtainable by running the Idle Report through the Reporting API (if that report is published to the API). |
| 7 | **Overtime run** | `payroll/v2 …/gross-pay-items` → `paidTimeType`, `paidDurationHours`, `date`, `employeeId`, `businessUnitName` (200) | Sum paid hours where pay-type = Overtime, by day/tech/BU | **POSSIBLE** | — (confirm at build time that `paidTimeType` carries an "Overtime" value — field is present; its values weren't dumped) |
| 8 | **Time to first call (dispatch→arrival gap)** | `dispatch/v2 …/appointment-assignments` → `assignedOn` (200); `jpm/v2 …/appointments` → `arrivalWindowStart/End`, `start` (200) | Dispatch time vs actual arrival time | **PARTIAL** | Dispatch time (`assignedOn`) is available. **Actual arrival timestamp is not exposed** — `arrivalWindowStart/End` is the promised window, not when the tech arrived. The real gap needs GPS/"arrived" event data (likely only via the Dispatch report), not these endpoints. |
| 9 | **Booking % (Avoca Dashboard)** | — (Avoca, external system) | — | **NOT POSSIBLE** *(via ServiceTitan)* | Avoca is a separate platform. Needs Avoca's own API/export — flagged in WHERE-WE-ARE.md as a later phase. |
| 10 | **3-day call board full %** | `dispatch/v2 …/capacity` (**403 Forbidden** in probe); fallback: `technician-shifts` + `appointments` | ST board fill for tomorrow / +2 / +3 days | **PARTIAL** | The capacity endpoint that gives ST's own board-fill % is **forbidden under the app's current scopes** (403 = authorized app, unauthorized resource). Fix: add the capacity/dispatch scope to "Sierra Claude Access," or approximate fill from booked appointment hours ÷ shift hours (not identical to ST's board). "Including expected inbounds" is a forecast — not an API value at all. |
| 11 | **Tune-ups in/out of the 3-day board** | `jpm/v2 …/jobs`/`appointments` → `jobTypeId`, `start`; `dispatch/v2 …/capacity` (403) | Are tune-up-type jobs counted inside the capacity board? | **PARTIAL** | Tune-up jobs are identifiable by job type and schedule date. But "in/out of the board" is a capacity-board concept — blocked by the same 403 as #10. |
| 12 | **Booking rate by source (Angi, Schedule Pro, Avoca callbacks, LSA, Yelp)** | `crm/v2 …/bookings` → `source`, `campaignId`, `status`, `jobId` (200); `crm/v2 …/leads` → `campaignId` (200); Scheduling-Pro namespace for Schedule Pro | Booked ÷ opportunities per source | **PARTIAL** | Angi / Yelp / LSA / Schedule Pro appear as booking sources or campaigns and are computable. **Avoca callbacks are external (Avoca)** and not in ServiceTitan. Source-name → provider mapping must be defined once. |
| 13 | **Maintenances booked next 14 days** | `jpm/v2 …/appointments` → `start` + `jpm/v2 …/jobs` → `jobTypeId`; or `memberships/v2 …/recurring-service-events` → `date`, `status` (all 200) | Count maintenance/tune-up appointments scheduled within the next 14 days | **POSSIBLE** | — (define which job types count as "maintenance") |
| 14 | **Club members left to run (HVAC + Plumbing, daily)** | `memberships/v2 …/recurring-service-events` → `status`, `date`, `membershipId` (200); `…/recurring-services` → `businessUnitId`, `jobTypeId` (200); `…/memberships` → `active`,`status` (200) | Recurring-service events not yet completed ("left to run"); join to recurring-service for HVAC vs Plumbing split | **POSSIBLE** | — (HVAC/Plumbing split comes from joining events → recurring-service business unit / job type) |
| — | **Running totals: day / month / year-to-date** (cross-cutting) | Date filters on `jobs`, `bookings`, `gross-pay-items`, `recurring-service-events` (e.g. `completedOnOrAfter`, `createdOnOrAfter`) | Sum each metric over day/month/year ranges; past ranges are frozen, today is live | **POSSIBLE** | — (see totalCount note below) |

---

## Notes, caveats, and things a human must decide

**Verified live (200) endpoints & their key fields** — from the 2026-07-15 probe:
`jpm/jobs`, `jpm/appointments`, `jpm/job-cancel-reasons`, `crm/bookings`, `crm/leads`,
`dispatch/technician-shifts`, `dispatch/appointment-assignments`, `dispatch/non-job-appointments`,
`payroll/gross-pay-items`, `memberships/memberships`, `memberships/recurring-services`,
`memberships/recurring-service-events`, `telecom/calls`, `reporting/report-categories`.

**Endpoints that did NOT work as tried:**
- `payroll/v2 …/timesheets` → **404**. Payroll time data lives in `gross-pay-items` (which
  has `paidDurationHours`, `startedOn`, `endedOn`), not a `timesheets` collection at that path.
- `dispatch/v2 …/capacity` (POST) → **403 Forbidden**. The app authenticates fine but isn't
  scoped for capacity. This is the single biggest blocker (items 10 & 11). **Actionable fix:**
  add the capacity/dispatch scope to the "Sierra Claude Access" app, then re-connect — no code
  change needed. Until then, board-fill can only be *approximated*.

**Counting requires one extra step:** most list endpoints returned an empty `totalCount` in the
probe (only `telecom/calls` returned it by default: 697,252). ServiceTitan returns a total only
when you ask for it (an `includeTotal=true`-style parameter) or when you page through and count.
This is an implementation detail, not a coverage gap — every "count" metric can still be built.

**Reporting API is available** (`report-categories` = 200). This is the path to the two reports
Troy names directly — **Technician Performance Report** and **Idle Report**. It's the *only* clean
source for GPS-based idle time (#6). Caveats to plan around: it's rate-limited (roughly one run of
the same report per minute per tenant), and you must first discover the specific report's ID and
its required parameters. For calls-per-tech (#5) the raw-endpoint path is simpler and not
rate-limited, so prefer that; reserve the Reporting API for idle time.

**Business decisions still needed (not API problems):**
- What counts as a "call" for the call-count number (completed jobs? booked jobs? something else)?
- Which `businessUnitId`s map to **HVAC** vs **Plumbing** (needed for items 1, 2, 14).
- Definition of a "demand call" and of "same-day" (item 3).
- Which job types count as "maintenance"/"tune-up" (items 11, 13).
- Source-name → provider mapping for Angi/Yelp/LSA/Schedule Pro (item 12).

**Targets (later):** none of the above hard-codes a target. When targets are added they'll be
read from a config file and compared to these raw numbers; the data plumbing here doesn't change.

---

## One-line summary

| Verdict | Items |
|---|---|
| **POSSIBLE** | 1 Call count, 2 Cancellations, 5 Calls/tech, 7 Overtime, 13 Maintenances next 14d, 14 Club members to run, + running totals |
| **PARTIAL** | 3 Demand calls not booked, 4 Reschedules, 6 Idle vs working, 8 Time to first call, 10 3-day board %, 11 Tune-ups in/out of board, 12 Booking rate by source |
| **NOT POSSIBLE via ServiceTitan** | 9 Avoca booking % (separate system — later phase) |
