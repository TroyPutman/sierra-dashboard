# SILO-FLIP-HANDOFF — matching the SILO manager's flip rate (investigated 2026-08-10)

Paste-ready handoff so a fresh session can **build** this without re-running the investigation.
Everything below was verified against **live ServiceTitan data on 2026-08-10**. Read `CLAUDE.md`
(hard rules) and `DECISIONS.md` first; this file is the investigation record + build spec for one
metric only.

**Status: INVESTIGATION COMPLETE, NOT BUILT.** No code has been written. The method is proven to
reproduce the manager's numbers; what remains is the build.

---

## 0. Why this exists

Our dashboard's SILO flip rate **disagrees with the SILO manager's dashboard**:

| | Definition | YTD |
|---|---|---|
| **Ours (current, live today)** | turnover jobs that sold an estimate / total turnover jobs created | **38.5%** |
| **Theirs (target)** | TGLs created / ROPP calls ran | **48.4%** (2357 / 4872) |

Different numerator **and** different denominator. The business owner wants **ours to match theirs**.
Adopting their method moves the displayed number by ~10 points.

**Where ours currently comes from:** the existing SILO flip is computed inside the SILO-revenue
metric from Reporting API report **648754648** (category `technician`, `DateType=2`), as
sold / total turnovers — see `HANDOFF.md` §1 "SILO revenue (sold/signed value) + flip rate".
That is a *different* report from the two below. Decide deliberately whether the new metric
**replaces** that flip figure or sits alongside it (recommendation in §7).

---

## 1. The verified method

```
flip rate = (TGLs created) / (ROPP calls ran)
```

- **Count-weighted rollups only:** `sum(numerators) / sum(denominators)`.
- **NEVER average per-tech (or per-anything) percentages.**
- Rates **above 100% are legitimate and must render**. The manager's own non-SILO MTD currently
  reads **111.1%**. Do not clamp, hide, or treat >100% as an error.

### Numerator — "TGLs created"
- Report **642925621**, category **`technician`**, saved in this tenant as **"ROPP TGLS CREATED (JOHN)"**.
- Parameters: **`DateType=3`**, `From`, `To`. (Optional: `BusinessUnitId`, `IncludeAdjustmentInvoices`.)
- Date key: **column index 4 = `ScheduledDate`** (1-based column 5).
- **Count ROWS** whose `ScheduledDate` falls in the period.

### Denominator — "ROPP calls ran"
- Report **379143819**, category **`accounting`**, saved in this tenant as
  **"Johns Copy of Ericka's Revenue by Job Type"**.
- Parameters: **`DateType=1`**, `From`, `To`. (Optional: `BusinessUnitId`, `HideEmptyInvoices`.)
- Date key: **column index 3 = `CompletionDate`** (1-based column 4).
- **Count ROWS** (explicitly **NOT** distinct jobs) that survive cleaning.

### Periods used
| Period | From | To |
|---|---|---|
| YTD | `2026-01-01` | `2026-08-10` (today) |
| MTD | `2026-08-01` | `2026-08-10` (today) |

---

## 2. Report column layouts (verified from live metadata)

**642925621 "ROPP TGLs Created"** (0-based index → field name):

| idx | field |
|---:|---|
| 0 | `JobNumber` |
| 1 | `JobType` |
| 2 | `AssignedTechnicians` |
| 3 | `JobBusinessUnit` |
| **4** | **`ScheduledDate`** ← date key |
| 5 | `LeadCreated` |
| 6 | `LeadCreatedBy` |
| 7 | `SalesFromLeadsCreated` |
| 8 | `Tags` |

**379143819 "Revenue by Job Type"** (0-based index → field name):

| idx | field |
|---:|---|
| 0 | `JobType` |
| 1 | `Number` (invoice #) |
| **2** | **`JobNumber`** ← join key |
| **3** | **`CompletionDate`** ← date key |
| 4 | `InvoiceDate` |
| 5 | `Status` |
| 6 | `AssignedTechnicians` |
| 7 | `JobTags` |
| 8 | `Opportunity` |
| 9 | `InvoiceBusinessUnit` |

> The Reporting API returns field **names** alongside data. **Validate names against these indices
> at runtime and fail loud on mismatch** — do not trust bare indices (see fragility §6.1).

---

## 3. Cleaning rules (denominator only)

Applied **per distinct `JobNumber`**, in **exactly this order**; then count the **rows** belonging
to kept job numbers.

1. Job **not returned** by the jobs API at all → **KEEP** (*fails open*).
2. Else has tag **`545867780`** (Management Removed) → **DROP**.
3. Else does **NOT** have tag **`962027`** (ROPP) → **DROP**.
4. Else `jobStatus != "Completed"` **AND** the JobNumber is **not a TGL source call** → **DROP**.
5. Else → **KEEP**.

**Locked interpretations** (confirmed by the business owner during the investigation):
- **"TGL source call"** = a `JobNumber` that appears in the **numerator** report 642925621's rows
  (column index 0) **for the same period**. So a non-completed job is kept only if it created a TGL.
- **Job lookup is via the jobs API keyed by `JobNumber`.** If a JobNumber can't be resolved,
  **fail open (keep)**, exactly as rule 1 says. Fail *loud* only if the lookup **mechanism** breaks
  (e.g. jobs API unreachable) — never on individual missing jobs.
- Do **not** substitute the report's own `JobTags` / `Status` columns for the API lookup; that would
  deviate from the manager's method.

### Job-lookup approach that worked
Bulk-pull `/jpm/v2/tenant/{tenant}/jobs` and build a `jobNumber -> {jobStatus, tagTypeIds}` map:
- window A: `completedOnOrAfter` / `completedBefore` covering the CompletionDate window → 40,316 jobs
- window B: `createdOnOrAfter` / `createdBefore` (same span) to catch **non-completed** TGL-source
  calls → 1,609 additional jobs
- **41,925 jobs total → 100% coverage** of denominator JobNumbers (failed-open count = **0**).

**Page at `pageSize=200`. NEVER 300** — this tenant returns byte-identical duplicate rows at exactly
300 (CLAUDE.md hard rule 7).

Useful quirk of this tenant: **`jobNumber == id`**, which is why the string key maps cleanly.

---

## 4. Verified results (live pull, 2026-08-10)

### YTD — **48.45%**
| | ours | manager's doc |
|---|---:|---:|
| Numerator (TGL rows) | **2361** | 2357 |
| Denominator (kept rows) | **4873** | 4872 |
| **Flip** | **48.45%** | **48.4%** |

Delta = **+4 numerator rows, +1 denominator row out of ~4,900**. This is snapshot drift, not a
method difference: the metric is **retroactive** (TGLs keep getting scheduled), so a later snapshot
reading slightly higher is the expected direction.

### MTD — **68.02%**
| | ours | manager's doc |
|---|---:|---:|
| Numerator | **168** | — |
| Denominator | **247** | — |
| **Flip** | **68.02%** | **~67.1%** (given as approximate) |

At 247 calls, 2–3 calls move the rate ~1 point. Consistent with the same settling drift.

### Full intermediate breakdown
| | YTD | MTD |
|---|---:|---:|
| Numerator raw rows | 2361 | 168 |
| Numerator after ScheduledDate filter | 2361 | 168 |
| Denominator raw rows | 4873 | 247 |
| Denominator after CompletionDate filter | 4873 | 247 |
| Distinct JobNumbers | **4848** | 247 |
| Dropped — Management Removed | **0** | 0 |
| Dropped — not ROPP-tagged | **0** | 0 |
| Dropped — not Completed & not TGL source | **0** | 0 |
| Failed open (job not found) | **0** | 0 |
| **Final kept rows = denominator** | **4873** | **247** |

---

## 5. Three findings that shape the build

### 5.1 The cleaning rules are currently **no-ops**
Every denominator job resolved, **all** carried the ROPP tag, **none** were Management-Removed, and
**all** were `Completed`. Report 379143819 is effectively **pre-filtered** to exactly the population
the rules describe.

**Implication:** the rules are verified to *run*, but their DROP paths are **untested against real
data**. Still implement them faithfully — if John ever edits that report, they start mattering
**silently**. Consider logging drop counts so a future change is visible rather than invisible.

### 5.2 Row-vs-distinct counting is **load-bearing** — not incidental
YTD: **4873 rows vs 4848 distinct jobs** = **25 jobs carrying multiple invoices**.
- Counting **rows** → 4873 ≈ target 4872 ✅
- Counting **distinct jobs** → 4848, **misses the target by ~24** ❌

The manager's "count ROWS, not distinct jobs" rule inflates calls-ran by ~0.5%. It must be
preserved to match. (MTD had no duplicates: 247 == 247.)

### 5.3 The date-field mismatch is real but subtler than the doc implies
The two sides **do** key on different date fields (`ScheduledDate` vs `CompletionDate`). That
structural mismatch is what makes **>100% reachable** in small samples, and it is inherent to using
these two reports.

**However**, the *secondary* effect did not materialize: **raw rows == date-filtered rows on all
four pulls** (2361==2361, 168==168, 4873==4873, 247==247). With `DateType=3` the numerator's
`From`/`To` window on `ScheduledDate`, and with `DateType=1` the denominator's window on
`CompletionDate` — the **server-side window and the counted column agree**, so client-side date
filtering dropped **zero** rows.

**This is the single most important build consequence — see §7.2.**

---

## 6. Two fragilities

### 6.1 Both reports are **John's personal copies**
- 642925621 = "ROPP TGLS **CREATED (JOHN)**"
- 379143819 = "**Johns Copy** of Ericka's Revenue by Job Type"

If he renames, deletes, or **edits** either report, our number breaks or — worse — **silently
shifts**. Per CLAUDE.md hard rule 1 the metric must **error visibly** when:
- a report ID no longer resolves, **or**
- the returned field names don't match the expected column layout in §2.

Never fall back to a stale or last-known number.

Also note the report-list endpoint **pages at 50**; category `technician` had **92 reports**, and
642925621 was **not in the first page** — page with `?page=N&pageSize=50` and honor `hasMore` if you
ever re-discover these by name.

### 6.2 The Reporting API **429-throttles** rapid successive POSTs
This tenant throttles consecutive report-data POSTs with roughly a **60-second** backoff.
- The verified run used **~65s `Start-Sleep` between POSTs** and hit **zero 429s**.
- A full refresh needs **4 POSTs** (numerator + denominator) × (YTD + MTD) ⇒ **~4–5 minutes**.
- An earlier attempt died on a 2-minute shell timeout waiting on the built-in 429 retry.

**This is far too slow to run on-demand inside `serve.ps1`.** It forces the caching design in §7.3.

---

## 7. Recommended build approach

### 7.1 Replicate the method **exactly** — quirks included
The data makes this clearer than theory did: row-counting is **required** to hit their number
(§5.2), and the date-field mismatch is inherent to using their reports. A "cleaner" version
(aligned date fields, deduped to distinct jobs) lands near **48.2%** and would **drift further from
the manager over time** — re-creating the exact divergence this work exists to eliminate.

**So: copy it faithfully, and document the quirks in the tab's notes** so a >100% reading reads as
faithful-to-source rather than a bug. The knowingly-accepted cost is a ~0.5% row inflation and a
mixed date basis.

### 7.2 ⚠️ Do NOT do client-side date parsing — use per-period server-side windows
The investigation script *did* parse dates client-side
(`[datetime]::Parse(...).ToString('yyyy-MM-dd')`, keep if it starts with `2026` / `2026-08`). **Do
not carry that into the build.** Per `HANDOFF.md` §1, client-side date parsing of report rows
**broke the SILO metric twice**: the report's offset was preserved on Windows PS 5.1 but normalized
to UTC on the Linux/UTC `pwsh7` CI runner. The fix was to remove client-side date parsing entirely.

This is safe to drop **because §5.3 proved the client-side filter removes zero rows** — the server's
`From`/`To` window already does the bucketing. So:

- Do **one pull per period** with `From`/`To` as **plain Pacific date strings** and let the report
  bucket server-side (same pattern as the existing SILO revenue metric).
- Count the returned rows directly. **No client-side date parsing of report rows.**
- Optionally keep a **fail-loud guard** that counts rows whose date key falls outside the requested
  window and errors if it's ever non-zero — that guard is what caught the bug last time.

### 7.3 Caching (required, not optional)
Because of §6.2 (~4–5 min per full refresh), do **not** compute this inside `serve.ps1` on request.

- Compute in the **refresh layer** (`refresh-silo.ps1`, which the GitHub Actions workflow already
  runs) and **persist** to a cache file under `data/` — mirror the existing
  `data/revenue-<month>.json` / `data/silo-<month>.json` pattern.
- **Do not freeze it.** Like SILO revenue, this metric is **retroactive** — a TGL scheduled later
  lands on an earlier day. Recompute current period every run (`final:false`).
- The dashboard reads the cache. Surface an **"as of" timestamp**; if the cache is **missing or
  unreadable, fail loud on screen** — never render a stale number silently (CLAUDE.md rule 1).
- Space the 4 POSTs by ~65s inside that refresh script; keep the existing 429 retry as a backstop.

### 7.4 Layering + config (respect CLAUDE.md rule 3 and rule 2)
- **`lib/st-common.ps1`** (data): the Reporting API POST helper + 429 retry lives here (a helper of
  this shape already exists — reuse it, don't duplicate).
- **`lib/metrics.ps1`** (math): one `Get-Metric-*` function + `$METRIC_DEFS` registry entry.
- **`serve.ps1` + `dashboard.html`** (presentation): SILO tab render + notes documenting the quirks.
- **`config.json`**: put the **report IDs, categories, `DateType` values, and expected column
  names** in config — not hard-coded — following the precedent set by
  `callBoard.nonOpportunityJobTypeIds`. Tag IDs `962027` / `545867780` should also be config-driven.
  **Fail loud** if any is missing or unresolvable.
- Existing goal key **`silo-flip-ytd`** already tracks the YTD flip figure; changing the underlying
  definition changes what that bar measures. Re-state the goal with the business owner.

### 7.5 Verification bar for "done"
- Reproduce **YTD ≈ 48.45% (2361/4873)** and **MTD ≈ 68.02% (168/247)** from the built metric, with
  drift explained — not forced.
- Verify at **1920×1080** that the SILO tab still fits one screen (project convention).
- Test the **fail-loud paths**: bogus report ID, and a deliberately wrong expected column name.
- Log/print the per-rule drop counts once so §5.1 stays observable.

---

## 8. What **NOT** to do

1. **Do NOT adjust the method to force a match** to 48.4% / 67.1% (or any expected number). If the
   built metric disagrees, **stop and explain why**. Small drift is expected and acceptable;
   silently tuning the method is not. (CLAUDE.md rule 1.)
2. **Do NOT dedupe the denominator to distinct jobs.** Count **ROWS**. Deduping costs ~24 rows YTD
   and breaks parity with the manager (§5.2).
3. **Do NOT average percentages** (per tech, per BU, per day). Roll up count-weighted:
   `sum(num) / sum(den)`.
4. **Do NOT clamp or hide rates >100%.** They are reachable and the manager renders them.
5. **Do NOT reintroduce client-side date parsing** of report rows (§7.2) — it broke this project
   twice cross-platform.
6. **Do NOT page the jobs API at `pageSize=300`** — duplicate rows (CLAUDE.md rule 7).
7. **Do NOT hard-code** report IDs, tag IDs, or targets — config only (CLAUDE.md rule 2).
8. **Do NOT substitute** the denominator report's `JobTags`/`Status` columns for the jobs-API
   lookup in the cleaning rules — it deviates from the manager's method.
9. **Do NOT compute this synchronously in `serve.ps1`** — ~4–5 min of throttled POSTs (§6.2/§7.3).

---

## 9. Open gaps / not verified

- **`DateType` semantics were not independently verified.** `DateType=3` (numerator) and `DateType=1`
  (denominator) were taken from the manager's handoff doc; they produced matching numbers, which is
  strong evidence but not a spec. Note the existing SILO revenue metric uses `DateType=2` on a
  different report — the enum is per-report, so don't assume a global meaning.
- **The manager's dashboard was never opened.** Parity is inferred from matching totals against
  their written figures (2357/4872 and ~67.1%), not from reading their UI.
- **The DROP paths of the cleaning rules are untested against real data** (§5.1) — no live row has
  ever exercised them.
- **The MTD target (~67.1%) was approximate**, so 68.02% could not be reconciled exactly.
- Whether the new figure should **replace** the existing 38.5% flip or display alongside it is a
  **business decision that has not been made** (§0, §7.4).

---

## 10. Reproducibility

- Auth: `New-StContext` from `lib/st-common.ps1` (bearer token from
  `POST auth.servicetitan.io/connect/token` using `secrets.json` `clientId`/`clientSecret`, plus the
  `ST-App-Key` header). The Reporting API is **reachable with current credentials — no extra OAuth
  scope needed** (verified: `GET /reporting/v2/tenant/{tenant}/report-categories` → HTTP 200,
  12 categories).
- Endpoints used:
  - `GET  /reporting/v2/tenant/{tenant}/report-categories`
  - `GET  /reporting/v2/tenant/{tenant}/report-category/{category}/reports?page=N&pageSize=50`
  - `GET  /reporting/v2/tenant/{tenant}/report-category/{category}/reports/{reportId}` (metadata)
  - `POST /reporting/v2/tenant/{tenant}/report-category/{category}/reports/{reportId}/data`
  - `GET  /jpm/v2/tenant/{tenant}/jobs` (pageSize 200)
- Request bodies: numerator `parameters=[{DateType:3},{From},{To}]`;
  denominator `parameters=[{DateType:1},{From},{To}]`.
- Environment: **Windows PowerShell 5.1** (`powershell.exe -ExecutionPolicy Bypass`) —
  **`pwsh` is not installed on this machine**. Note the CI runner *is* pwsh7 on Linux/UTC, which is
  why §7.2 matters.
- The investigation scripts/logs lived in the session **scratchpad only** (never committed) and are
  **ephemeral** — treat this document, not those files, as the source of truth.
