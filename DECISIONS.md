# DECISIONS.md — Business-rule decision record

**What this file is:** every business rule the dashboard encodes, who decided it, **why**, and what it did
to the numbers. A metric is only as good as the definition behind it, and most of these definitions are
judgement calls that could reasonably have gone the other way. If you are about to "fix" a number that
looks wrong, read the relevant entry first — it may be deliberate.

**Doc roles (keep them separate):**
- **WHERE-WE-ARE.md** — project status: what is built, what happened when, what is still open.
- **DECISIONS.md** (this file) — the business rules and the reasoning behind them.
- **SPEC.md** — how to build each metric (endpoints, fields, step-by-step calculation).
- **API-COVERAGE.md** — what the ServiceTitan API can and cannot provide.

**Status labels used below:**
- **BUILT** — decided and live in the dashboard.
- **DECIDED — NOT BUILT** — the rule is settled, the code does not do it yet.
- **OPEN** — still needs a human answer.

> ⚠️ **SPEC.md is now out of date for M2, M3 and M4.** It still describes the pre-2026-08-03 definitions.
> Where SPEC.md and this file disagree, **this file is correct**. SPEC.md should be reconciled.

---

## The two corrections that matter most

If you read nothing else, read these. Both mean previously-reported numbers were wrong.

### 1. Every overtime number before 2026-08-03 was overstated by roughly a third

The payroll endpoint returns **byte-identical duplicate rows across page boundaries at page size 300
specifically**. Page size 200 and 2500 both return zero duplicates. This is a server-side defect, not our
paging code — the same day pulled repeatedly returned the same total row count but a different set of rows,
with overtime counts swinging between 619 and 1,360.

The dashboard's overtime metric was reading at exactly 300. Corrected to 2500 (a work day fits in one page;
the API cap is 5000).

| 2026-07-15 overtime | Before | After |
|---|---|---|
| HVAC – Service | 362.0 hrs | **250.9 hrs** |
| Plumbing – Service | 167.9 hrs | **130.0 hrs** |
| **Total** | **529.9 hrs** | **380.9 hrs** (−28%) |

Confirmed two independent ways: the dashboard and the standalone script now agree to a tenth of an hour.
**Any overtime figure quoted in older documents or emails is inflated.**

**Never use page size 300 anywhere in this project.**

### 2. "Verified" past days are not frozen, and cannot be

Troy verified 19 cancellations for 2026-07-15 on 2026-07-16. A live pull on 2026-07-29 returned 28. Fully
explained, with no residual:

- **−2**: Troy counted cancelled *jobs*; the metric counted cancelled *visits*. Two jobs were cancelled
  while their visit stayed marked "Done", so the metric never saw them. On the day, it would have said 17.
- **+11**: cancellations recorded *after* Troy looked, which still file back onto 2026-07-15 because a
  cancellation is dated to the day the work was **booked for**, not the day it was cancelled.

**Ten of those eleven were a single administrative sweep on 2026-07-17** — one person deleting ten duplicate
"QA Crew Check" jobs in about 90 seconds, reason "Duplicate entry". No customer work was lost.

The lesson generalises: **any past day's cancellation count can rise indefinitely.** The old
"past days are frozen" design was built on an assumption that is false for this metric.

---

## M1 — Call count

### M1.1 Maintenance visits count as calls — BUILT (no change needed)
**Decided:** Troy, 2026-08-03.
**Why:** a maintenance visit consumes a board slot and a technician's time like any other call. Troy reads
the number as "work we ran", not "service demand".
**Effect:** none — this confirms existing behaviour. Worth knowing that this is a deliberate choice: the
maintenance business unit alone books ~290 visits in a two-week window, so it is a large share of the count.

### M1.2 One job = one call, even with several visits the same day — BUILT (no change)
**Decided:** Troy, 2026-08-03. **Why:** the call is the opportunity, not the number of trips it took.
**Note:** callbacks may become a separate metric later. **Deliberately not built now.**

### M1.3 Booked and completed are separate numbers and are not meant to reconcile — BUILT (no change)
**Decided:** Troy, 2026-08-03.
**Why:** a call booked Monday and finished Wednesday lands in Monday's booked figure and Wednesday's
completed figure. They count different jobs by design.
**Do not** subtract one from the other to imply a backlog.

---

## M2 — Cancellations

Rewritten wholesale on 2026-08-03. Six decisions, applied in order.

### M2.1 A rescheduled visit is NOT a cancellation — BUILT
**Decided:** Troy, 2026-08-03. **Why:** only genuinely lost work should count.
**Effect: removed nothing.** In this tenant a reschedule does not leave a cancelled visit behind — verified
across ten sampled days, zero cases. The rule is correct but currently inert.

### M2.2 One job = one cancellation — BUILT
**Decided:** Troy, 2026-08-03. **Effect: removed nothing** — no job had two cancelled visits on the same
day in any sampled day. Implemented anyway for correctness.

### M2.3 Administrative cleanup is NOT a cancellation — BUILT
**Decided:** Troy, 2026-08-03. **Why:** deleting a duplicate record is bookkeeping, not lost work.

**Excluded reasons** (by ID, since names can be re-typed):

| ID | Reason | Uses in 90 days |
|---|---|---|
| 102 | Duplicate entry | 762 |
| 656703594 | Avoca Duplicate | 71 |
| 403340016 | History call clean up | 0 (retired) |
| 398228702 | Reschedule | 0 (retired) |

"Avoca Duplicate" is the answering service booking a job already on the board. Troy confirmed its exclusion
on 2026-08-03. Every exclusion is **counted and shown on screen** so it is auditable, never a silent drop.
This list could move to `config.json` if Troy wants to edit it without touching code.

**Effect on 2026-07-15: −13.**

### M2.4 Count as of whenever we look, not as of that day — BUILT
**Decided:** Troy, 2026-08-03. **Why:** consistent with wanting past days to update.
**Consequence, and it is on screen:** yesterday's count is **not final** and can still rise. The metric
displays a warning saying so. This was demonstrated live — 2026-07-29 read 25, then 29 a few days later.

### M2.5 Count a cancellation even if the visit was left marked "Done" — BUILT
**Decided:** Troy, 2026-08-03. **Why:** it fixed a real undercount — the job is cancelled, so the work was
lost, regardless of what the visit record says.
**Effect on 2026-07-15: +2.** Roughly 1–2 per day.

### M2.6 A multi-day job counts once, on its first booked day — BUILT
**Decided:** Troy, 2026-08-03. **Why:** a cancelled three-day install is one lost job, not three.
**Effect: removed nothing on either test day** — almost all jobs are single-visit.
**Implementation note:** the anchor day uses **all** of the job's visits regardless of status, so the anchor
cannot drift between pulls as visits get cancelled one at a time.

### Net effect

| Day | Before | After |
|---|---|---|
| 2026-07-15 | 28 | **17** |
| 2026-07-29 | 29 | **25** (later 29, see M2.4) |

### M2.7 "Problem fixed itself (CSR tried to save)" stays counted — BUILT, but flagged
**Decided:** Troy, 2026-08-03 — *provisionally*, pending the analysis below.

This is the **single largest cancellation reason: 1,110 uses in 90 days, 38.2% of all cancellations.**
A full investigation found it is **largely a catch-all — roughly 1 use in 10 matches what the label says.**

**Recommendation on file: leave it counted.** It mostly represents real lost work, just not the specific
thing the label claims. The fix is a better reason list and a conversation with the CSR team, not a filter.
**If Sierra adds a "Customer cancelled / will reschedule" reason, revisit this.**

The full analysis follows, because this is the part Troy can act on.

#### Every cancellation reason actually in use (90 days, 2026-04-30 → 2026-07-29)

Only **9** of the 15 catalogued reasons were used at all. Total 2,907 cancellations.

| Reason | Count | Share |
|---|---|---|
| Problem fixed itself (CSR tried to save) | 1,110 | 38.2% |
| Duplicate entry | 762 | 26.2% |
| 3 attempts at contact, no response | 354 | 12.2% |
| H/O can't today – Lead Follow up | 229 | 7.9% |
| Tech was late | 162 | 5.6% |
| Competitor arrived | 138 | 4.7% |
| Negative experience | 73 | 2.5% |
| Avoca Duplicate | 71 | 2.4% |
| Going with Install over Repair | 8 | 0.3% |

Share is stable month to month: May 39.0%, June 36.4%, July 39.0%.

#### The decisive evidence — who uses it

This is the table to act on. It shows **what share of each person's own cancellations get this one code**:

| Person | Total cancellations | Coded "problem fixed itself" | Share | Distinct reasons they use |
|---|---|---|---|---|
| Ciara Stoner | 39 | 38 | **97.4%** | 2 |
| Ashley Morales | 93 | 90 | **96.8%** | 4 |
| Kayla Mergersen | 159 | 149 | **93.7%** | 3 |
| Esteisi Morales | 94 | 87 | **92.6%** | 2 |
| Devon Hernandez | 73 | 67 | **91.8%** | 3 |
| Jeremy Von Samson | 94 | 70 | 74.5% | 6 |
| Nancy Rodriguez | 300 | 131 | 43.7% | 5 |
| James Douglas | 119 | 15 | 12.6% | 8 |
| Warren Taylor | 169 | 7 | 4.1% | 3 |
| Abigail Solano | 142 | 0 | **0.0%** | 3 |
| Greg Sabataso | 125 | 0 | **0.0%** | 1 (all "Duplicate entry") |
| Ryan Hernlund | 295 | 0 | **0.0%** | 6 |

**Five people apply this code to over 90% of everything they cancel. Three equally busy colleagues never use
it once.** Ryan Hernlund handled 295 cancellations without a single customer's problem fixing itself, while
Ciara Stoner had it happen 38 times out of 39. **The same real-world event is being coded differently
depending on who answers the phone.** That divergence cannot come from customers.

Note that raw volume concentration is *not* unusual — the top 3 users account for 33.4% of this reason
versus 34.8% for all other reasons combined. Cancelling is simply a concentrated activity. It is the
*per-person mix* above, not the volume, that reveals the problem.

#### Ten real examples

Chosen mechanically — all 1,110 sorted by cancellation time, then the midpoint of each of 10 equal
time-slices. No hand-picking. **Only #7 and #8 describe a problem that actually went away.**

| Job type / unit | Cancelled by | Booked → cancelled | Note (verbatim) |
|---|---|---|---|
| SAM Cooling Service (2 System) / HVAC-Maint | Christian Penagos | 21.1 days | `will go too their warranty company instead` |
| SAM Cooling Service (1 System) / HVAC-Maint | Ariana Burns | 35.7 days | `H/O CALLED IN TO CXL FOR NOW AS HER HUSBAND HAS TO GO TO THE HOSPITAL. SHE WILL CB TO RESCHED WHEN CONVENIENT` |
| Plumbing Faucet Issue/Leak / Plumbing-Svc | Kaylah Deitz | 3.6 hours | `BOOKED UNDER WRONG ADDRESS UNSURE WHAT HAPPENED` |
| AC Issue 8+ yrs / HVAC-Svc | Devon Hernandez | 30.3 days | `HAD TO CXL DUE TO A PASSING IN THE FAMILY` |
| AC Issue 8+ yrs / HVAC-Svc | Ashley Morales | 4.0 hours | `WANTED TECH THERE IN 30 MINS ADV WE WOULD CALL WHEN OTW. RATHER JUST CXL` |
| Plumbing Estimate Tankless WH / Plumbing-Svc | Kaylah Deitz | 4.0 days | `H/O REQ TO CXL TRIED TO RESCHD HE DOESNT WANT A NEW SYSTEM AT THIS TIME` |
| Estimate AC / HVAC-Sales (NR) | Kayla Mergersen | 17.7 hours | `H/O EMAILED US AND WANTED TO CANCEL BOOKING` |
| Install HVAC Part 4-5 HRS / HVAC-Svc | Nancy Rodriguez | 24.2 days | `CALLED H/O TO SCHED AND COLLECT PAYMENT H/O ADV WOULD LIKE TO CXL DONT WANT TO MOVE ON FORWARD` |
| ✅ AC Issue 4-7 yrs / HVAC-Svc | James Douglas | 16.4 hours | `Customer called to cancel, turned out it was just the sound of weather, not his unit` |
| ✅ Install HVAC Part 1-2 HRS / HVAC-Svc | Ariana Burns | 1.6 days | `H/O CALLED IN TO CXL, UNIT IS WORKING FINE NOW` |

The other eight describe a warranty company, a hospital emergency, a booking-address error, a death in the
family, an impatient customer, a declined estimate, an email cancellation, and a customer backing out of a
paid repair. **None of them is "the problem fixed itself."**

#### What the notes actually say

Notes are **100% filled in** (the field appears to be mandatory) and genuinely written — 1,029 distinct
texts across 1,110 entries, averaging 66 characters, none identical to the reason name. So "blank note =
catch-all" is not an available test. Testing the *content* instead:

| The note reads like… | Count | Share |
|---|---|---|
| A reschedule / "will call back" | 275 | 24.8% |
| The problem genuinely resolving | ~95 | ~8.6% |
| A duplicate / wrong ticket / booked in error | 42 | 3.8% |
| No answer / no contact (already a reason) | 37 | 3.3% |
| Went with another company (already a reason) | 27 | 2.4% |
| **Describes a reason that already exists on the dropdown** | **370** | **33.3%** |

Notes mentioning the problem resolving are **10× more common** on this reason than any other (8.6% vs 0.8%),
so the label does carry real signal — it is not junk data. But **roughly 9 in 10 describe something else.**

**The likely cause:** notes containing an explicit save attempt ("TRIED TO SAVE", "OFFERED TO RESCHED") are
**7× enriched** here versus other reasons (9.2% vs 1.3%). Staff appear to be selecting on the label's second
half — *"(CSR tried to save)"* — treating it as "the customer wanted to cancel and I tried to talk them out
of it," regardless of why. **There is no plain "Customer cancelled / will reschedule" option on the list,
and a quarter of these notes say exactly that.**

#### It is NOT people dumping tickets

Worth stating clearly, because it is the obvious suspicion and the data rules it out:

| | This reason | All other reasons |
|---|---|---|
| Median booking → cancellation | **46.9 hours** | 51.3 hours |
| Cancelled within 1 hour | 17.9% | 17.3% |
| Cancelled same day as booking | 33.8% | 31.6% |

Essentially identical. For contrast, "Avoca Duplicate" — a genuine record-hygiene code — has a **59-minute**
median with 52% inside an hour. That is what ticket-closing looks like, and this reason does not look like it.

There is also **no end-of-shift or weekend pattern.** Raw numbers appear to spike at 18:00 and on Sundays,
but that is entirely two evening/weekend CSRs (Esteisi Morales and Ashley Morales) who use this reason for
93% and 97% of their own cancellations. Remove those two and the evening share falls to 21.4% versus 22.3%
for all other reasons — flat. It is a *person* pattern, not a *time* pattern.

It is also spread across **87 distinct job types** and **all nine business units** (HVAC-Service 33%,
HVAC-Maintenance 20%, Plumbing-Maintenance 15%, Plumbing-Service 13%, HVAC-Sales 11%, rest smaller), and is
*less* clustered than other reasons. No single team or job type is responsible.

#### Best estimate of what the 1,110 actually are

~10% genuinely self-resolved · ~25% reschedules and will-call-backs (arguably not lost calls at all) ·
~10% duplicates, no-contact or competitor that belong under existing reasons · ~55% ordinary customer
cancellations with no single cause.

**Treating all 1,110 as "customers who no longer needed us" overstates that group by roughly 10×.**

#### What this data cannot tell you

- **Elapsed time is measured from job *creation* (booking), not from the scheduled appointment.** The
  cancellation export carries no appointment reference. So "cancelled 2 days after booking" is knowable;
  "cancelled 30 minutes before the tech was due" is not. Answering the second needs an appointments pull and
  would materially sharpen the genuine-change-of-mind versus day-of-no-show question.
- **Whether each note faithfully records what the customer said.** A note reading "H/O REQ CXL" could be
  hiding a self-resolved problem. The ~10% is a floor on explicit evidence, not a ceiling on truth.
- **Whether staff were ever trained on the reason list.** Dropdown position was checked and ruled out — the
  reason sits 8th of 9 alphabetically and is not in any default position. Something else drives the habit.
- **Whether the five heavy users or the three non-users are "right."** The data shows disagreement, not who
  is correct. That is a conversation with the CSR team — and the per-person table above says exactly who to
  ask.

---

## M3 — Calls per tech

### M3.1 Only the technician running the call counts — BUILT
**Decided:** Troy, 2026-08-03. Apprentices and ride-alongs must not count.
**Implementation:** no primary/lead flag exists in the data, so the primary is the **earliest-assigned**
active technician on each job, ties broken by lowest technician ID for reproducibility.
**Effect: none.** Only **1 job out of 99** on 2026-07-15 had a second technician assigned, and that person
was already the primary on another call. **The premise did not hold — ride-alongs were not inflating this
number.** 73 calls / 31 techs / 2.4 was already correct.

### M3.2 Month/year denominator = typical number working per day — DECIDED — NOT BUILT
**Decided:** Troy, 2026-08-03. Not "everyone who worked at any point in the period".
**Why:** counting every tech who appeared once in a month would inflate the denominator and understate
productivity. **Running totals are not built yet**; this rule is recorded in the code for whoever builds them.

---

## M4 — Overtime

### M4.1 Payroll workweek starts Friday — CONFIRMED
**Decided:** Troy, 2026-08-03.
**Why this matters:** overtime is always **zero on Fridays and Saturdays** and climbs through the week.
That is **correct, not a bug** — nobody has crossed the weekly hours threshold on days one and two of the
pay week. A Saturday or Sunday morning meeting will legitimately show zero overtime.
This was inferred from the data first (the only start day consistent with the pattern) and then confirmed.

### M4.2 Page size fix — BUILT
See "The two corrections that matter most" above. **−28% on 2026-07-15.**

### M4.3 Show all overtime AND job-only overtime side by side — DECIDED — NOT BUILT
**Decided:** Troy, 2026-08-03. **Why:** the current figure includes idle, driving and training time, which
makes it much larger than "overtime spent on calls". Troy wants both, not one or the other.

### M4.4 Show hours AND dollars — DECIDED — NOT BUILT
**Decided:** Troy, 2026-08-03.

### M4.5 Say when payroll is incomplete — DECIDED — NOT BUILT
**Decided:** Troy, 2026-08-03. **Why:** payroll is not always fully entered by the next morning — it depends
how busy the office is. The two most recent days consistently carry about **half** the payroll entries of
older days. Since the metric reports *yesterday*, it is systematically reading the least-complete day.
**The number must say when it is incomplete rather than silently showing a low figure.** Fail loud.

---

## M5 — Maintenances booked next 14 days

### M5.1 Straight 14-day total — BUILT
**Decided:** Troy, 2026-07-24. **Why:** the old "~50" expectation was never a target, just something noted
in passing, and it carried no weight. Verified at 502 on 2026-07-24. Sections and the per-day breakdown
remain as useful detail underneath the headline.

### M5.2 Window starts tomorrow, not today — DECIDED — NOT BUILT
**Decided:** Troy, 2026-08-03. **Why:** today is already largely booked, so including it flatters the number
and hides the dead space the metric exists to reveal.

### M5.3 Two visits for one customer count as two — BUILT (confirm)
**Decided:** Troy, 2026-08-03. **Why:** the metric counts calendar slots to fill, not customers.

---

## M6 — Club members left to run

### M6.1 A member is a house/location, not a customer — DECIDED — NOT BUILT
**Decided:** Troy, 2026-08-03. Two properties = two members, each needing its own maintenance before it
drops off the list.
**Why it matters:** currently matched at customer level, so a customer with two properties counts once — if
one property got its maintenance and the other did not, they **disappear from the list entirely**. This
understates the backlog.

### M6.2 Season flips cooling → heating in the last week of September, with no hard cut — DECIDED — NOT BUILT
**Decided:** Troy, 2026-08-03.
**Why the "no hard cut" part matters:** leftover cooling maintenances still get run after the switch, so the
metric must **keep showing unrun cooling members after the flip** rather than dropping them the moment the
season changes.
**Ownership warning:** nobody currently owns this switch or the date. It will silently go stale in the
autumn if no one acts.

### M6.3 16-month lookback is correct — CONFIRMED (no change)
**Decided:** Troy, 2026-08-03.

### M6.4 Which membership types count as HVAC — **OPEN**
**Status:** blocking accuracy. How HVAC memberships are currently identified is a **guess**, and it sets the
size of the entire member base (currently 9,633 active members, 1,998 left to run).
**Next action:** pull every membership type with its active member count and have Troy identify which are
HVAC. **Do not guess this.**

---

## M7 — Call board (next 14 days)

### M7.1 No HVAC/plumbing technician crossover — CONFIRMED (no change)
**Decided:** Troy, 2026-08-03. Technicians are counted against their home business unit, and Troy confirmed
crossover does not happen, so that grouping is safe.

### M7.2 Keep weekends, marked non-budgeted — DECIDED — NOT BUILT
**Decided:** Troy, 2026-08-03. **Why:** weekends legitimately run lighter. Currently a low-volume day renders
as a dashed "hole", which reads as a problem. Weekends should read as *expected*, not as a gap.

---

## M8 — Booking rate by source

### M8.1 Group by campaign category, not campaign name — BUILT
**Decided:** Troy, 2026-08-03. **Why:** name-matching one campaign at a time cannot keep up. Category
grouping means **new campaigns are picked up automatically** as marketing adds them.

Sources added: **Costco, SEO, Main Line Number, Google PPC, Texting, Outbound, Google Business Profile** —
alongside the existing Angi, Avoca, Yelp, LSA and Schedule Pro, which keep first-match priority.

| "Other" bucket, 30 days | Before | After |
|---|---|---|
| Leads | 411 | **35** |
| Share | 69.5% | **5.9%** |

What remains in "Other" is genuine long tail: Thumbtack, thermostat stickers, ReferPro, Bing, and a scatter
of one-offs.

### M8.2 30 days is the right period — CONFIRMED (no change)

### M8.3 Yelp shows zero leads, and that is a metric blind spot — NOTED, NOT FIXED
**Decided:** Troy, 2026-08-03 — do not change the logic yet, just record it.

**Yelp is running fine.** In 90 days: **152 calls** to the Yelp tracking number and **66 jobs** carrying a
Yelp campaign, continuing right up to the present. The last Yelp-attributed *lead*, however, was
**2026-03-03**.

**Why the dashboard shows zero:** around early March, Yelp traffic moved to a path where **Avoca books the
job directly without creating a lead record**. All 66 Yelp jobs have no booking record and no lead. The
metric reads only leads, so it correctly reports what it sees — the underlying business activity is simply
invisible to it.

**⚠️ This probably is not Yelp-specific.** Any source Avoca books this way is invisible here. It likely
explains why LSA and Avoca show conversions but no bookings. **Nobody has checked whether other campaigns
show the same pattern.** If they do, this metric may need rebuilding on jobs rather than leads.

---

## M9 — SILO / ROPP

### M9.1 The roster changes month to month — DECIDED — NOT BUILT
**Decided:** John via Troy, 2026-08-03. The 14-tech roster must be **derived per month, not held as a fixed
list**.
**Why:** Alex Yakovchuk shows 1 call in June against 303 across the year — he stepped up to help manage
during the busy season. A fixed list gives the wrong team total every month.

### M9.2 A "call ran" means a completed job carrying the ROPP tag — DECIDED — NOT BUILT
**Decided:** John, 2026-08-03. Jobs with no ROPP tag, **or where management removed the tag, do not count.**
**Why:** this is John's own definition; adopting it means the two reports can be compared without arguing
about the basis. This should also close most of the ~290-call gap over six months.

### M9.3 A technician who left mid-month still appears, with a partial number — DECIDED — NOT BUILT
**Decided:** John via Troy, 2026-08-03. **Why:** the work they did that month was real and should be visible.

**Current verified baseline (old definition):** June 2026 — 831 calls, 400 TGLs, 48.1% conversion.
Expect this to move once M9.1 and M9.2 are built.

### M9.4 The Revenue-tab flip rate is TGLs created / ROPP calls ran — BUILT 2026-08-10
**Decided:** business owner, 2026-08-10 — the dashboard must **match the SILO manager's number**, and the
new figure **replaces** the old one. Both are never shown together.
**What changed:** the flip rate on the Revenue tab used to be *turnover jobs that sold an estimate / total
turnover jobs created* (one report, 648754648), reading **38.5%** YTD. It is now *TGLs created / ROPP calls
ran* across two of the manager's own saved reports, reading **48.5%** YTD. Different numerator **and**
different denominator — the ~10-point move is a change of definition, not a bug fix.
**Why:** ours disagreed with the manager's dashboard, and the owner wants one number, not two.

Three quirks are copied **deliberately** because they are what make the number match; do not "clean" them up:
- **Count rows, not distinct jobs.** 25 jobs a year carry more than one invoice, so calls-ran reads ~0.5%
  high. Deduping gives 4848 against the manager's 4872 and misses by ~24.
- **Roll up count-weighted** (`sum(num)/sum(den)`), never by averaging percentages.
- **The two sides key on different date fields** (TGL scheduled date vs invoice completion date), so a short
  period can read **above 100%**. That is faithful to the source and is never clamped or hidden — the
  manager's own non-SILO MTD reads 111.1%.

**Cost and cadence:** a full recompute is 4 throttled report POSTs (~65s apart) plus a ~42k-job pull ≈ 5–6
minutes, against a CI job that refreshes every 15 minutes and normally finishes in 2–3. So it is computed in
the refresh layer into `data/silo-flip.json` behind a TTL (`config.json` → `siloFlip.cacheTtlSeconds`, 6h)
and only ever **read** at display time. It is never computed on request and never frozen (`final:false`) —
TGLs keep getting scheduled onto days already counted, so the figure keeps settling upward.

**Goal bar:** `silo-flip-ytd` still tracks the YTD flip, but it now measures the new definition, so its
target needs re-stating — the owner is setting it himself.

---

## Dispatch and arrival times — DECIDED — NOT BUILT

A new metric, fully specified but not started.

### D.1 The clock starts when the technician is dispatched
**Decided:** Troy, 2026-08-03. Not when he actually leaves.
**Why — deliberate:** sitting-around time between dispatch and rolling **is exactly what Troy wants to see.**
Do not "improve" this by excluding it.

### D.2 On time = first call of the morning, arriving before 8:30 AM when dispatched before 8:30
**Decided:** Troy, 2026-08-03.

### D.3 Time to first call is measured from first dispatch
**Decided:** Troy, 2026-08-03.

### D.4 Use nearest-pair-per-visit matching, not first-of-each-type
**Decided:** Troy, 2026-08-03.
**Why:** the dispatch and arrival events live on a per-*job* log, but the timings belong to individual
*visits*. Naively pairing the first dispatch with the first arrival on a multi-visit job produced gaps of
81 and 213 hours in testing. **This will silently poison any average if built the lazy way.**

**Feasibility (already verified):** dispatch and arrival timestamps exist on a per-job event log and are
**100% populated on completed jobs** (900 of 900 sampled). The lower overall figure of ~86% is entirely
cancelled and on-hold jobs, where no technician was ever dispatched — correct data, not missing data.
**Cost:** one API call per completed job, roughly 100 per day for the service units.

> **API-COVERAGE.md is wrong about this.** It states the actual arrival timestamp is not available and would
> need GPS data. It is available. That document should be corrected.

---

## Dashboard-wide

### DB.1 Month/year totals read as of the selected day — DECIDED — NOT BUILT
**Decided:** Troy, 2026-08-03. Picking a past date shows totals as of *that* date, not up to now.
Running totals are not built at all yet; this settles how to build them.

### DB.2 Backdated entries SHOULD change a closed day — DECIDED — NOT BUILT, AND IT BREAKS THINGS
**Decided:** Troy, 2026-08-03.

**⚠️ This contradicts the current design and the contradiction has not been resolved.** The dashboard
currently marks any past day "final" and serves it from cache forever, on the stated assumption that its
data is done. **That assumption is already false** — see the M2 investigation above, where a verified day
moved 47%.

**What breaks if past days become live:**
- **Speed.** Past days are currently instant. Recomputing on every view costs minutes on a cold pull, and
  the club-members metric is the slow part. A wall display polling every few minutes cannot afford that.
- **Consistency.** Troy may act on a number in the morning that has changed by the afternoon. The
  cancellations metric now carries an on-screen "can still rise" warning for exactly this reason; anything
  else made live needs the same treatment.
- **The "verified" label loses meaning.** Values recorded in these documents were true at the time and are
  not reproducible now.

**Recommended approach:** keep caching, but re-check past days on a schedule rather than freezing them
permanently, and show when each number was last computed. **Do not simply delete the freeze logic.**

### DB.3 Overview shows the next 3 days of maintenances as a small calendar — DECIDED — NOT BUILT
**Decided:** Troy, 2026-08-03. **Why:** so he can work with the scheduler to move bookings around.

### DB.4 Wall display is always on — CONFIRMED
**Decided:** Troy, 2026-08-03. Reinforces the outstanding need for a dedicated always-on machine.

---

## Still open

| # | Question | Impact |
|---|---|---|
| 1 | Which membership types count as HVAC (M6.4) | **Blocking** — sets the whole member base |
| 2 | Do other campaigns besides Yelp bypass lead creation? (M8.3) | **Blocking** — may invalidate the metric |
| 3 | Should "Problem fixed itself" stay counted once a better reason exists? (M2.7) | Affects ~38% of cancellations |
| 4 | How to reconcile live past days with dashboard speed (DB.2) | Design decision |
| 5 | Which always-on machine hosts the dashboard, and who owns keeping it running | Blocks real wall use |

---

## Conventions that must not be broken

1. **Fail loud.** A missing or failed number says so on screen. A real zero must look different from an
   error. Never a stale or guessed figure.
2. **No hard-coded targets.** Raw numbers only; any targets come from config at runtime.
3. **All day boundaries are Pacific**, converted to a UTC range for API filters. Never bucket by raw UTC date.
4. **Keep the three layers separate** — data, math, presentation. Adding a metric = one function, one
   registry entry, one tab render.
5. **Never page this tenant's API at size 300.** See the top of this file.
6. **Verify every filter parameter actually works.** This tenant has repeatedly accepted parameters and
   silently ignored them — business-unit filters on jobs, date filters on payroll, the pay-type filter on
   payroll, and the date filter on the cancellation export. Always confirm returned records honour the
   filter rather than assuming.
