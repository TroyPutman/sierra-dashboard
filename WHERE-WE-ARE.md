SIERRA MORNING DASHBOARD — PROJECT HANDOFF
AS OF: 2026-08-03. >> IF YOU ARE A FRESH SESSION, READ **HANDOFF-CURRENT.md** FIRST. << It has the current
build queue in priority order, what is blocked, and the traps that will otherwise cost you hours.
Then DECISIONS.md - the business-rule record (every definition, why it was chosen, and what it did to the
numbers). This file is status; DECISIONS.md is the reasoning; HANDOFF-CURRENT.md is what to do next.
>> TWO CORRECTIONS THAT INVALIDATE OLDER NUMBERS IN THIS FILE:
   (1) ALL OVERTIME FIGURES recorded before 2026-08-03 are INFLATED ~28-39% (payroll paging defect, fixed).
   (2) M2's "VERIFIED 19 for 2026-07-15" no longer reproduces - a past day's cancellation count keeps
       rising by design. Do not treat older recorded numbers in this file as reproducible. <<

>> START HERE (next session): read DECISIONS.md, then this file. SPEC.md third, and treat it with care -
it still carries the PRE-2026-08-03 definitions for M2, M3 and M4. All 9 metrics (M1-M9) are BUILT and the
dashboard runs via serve.ps1 (http://localhost:8787; the browser-preview helper uses 8791). Troy answered
ALL 34 open definition questions on 2026-08-03 - nothing is blocked on a definition any more except which
membership types count as HVAC. The next work is the DECIDED-BUT-NOT-BUILT queue in the STILL OPEN section
below (M4 features, M5 window, M6 per-house, M7 weekends, M9 roster, dispatch/arrival, Overview calendar,
running totals). M4's weekend zeros are RESOLVED - they are correct (Friday-start payroll week). <<

Who I am: Oliver, PM intern at Sierra Air Conditioning & Plumbing (Las Vegas). Very limited coding experience. Explain in plain English, one step at a time, write the code for me.
Goal: Troy Putman (GM) runs a daily morning meeting off a checklist that requires clicking through multiple dashboards. Build a self-updating dashboard so he spends less time at a computer and more time with employees.
WHAT IT IS:
A dashboard displayed on a screen mounted on the wall of Troy's office
Refreshes every few minutes — always-on, not something he opens
Shows RAW NUMBERS as they stand. This is NOT a goals/targets dashboard. No targets, no pass/fail, no red/green judgment — Troy reads the numbers and judges them himself.
Has a date picker — so it is NOT fully read-only; Troy can pick a day to view. Today's numbers update live throughout the day. Past days are frozen and complete (they don't change once the day is over).
Running totals matter: show day-to-date, month-to-date, and year-to-date for the relevant metrics.
Design accordingly: big text, readable from across a room, minimal interaction (date picker only)
TARGETS (LATER): targets/goals may be added eventually and will be read from a config file — do not build that now, but don't design anything that blocks adding it.
SCOPE: ServiceTitan first, then Avoca. 8x8 is out (workload moving to another company). Build on my laptop first, then produce handoff instructions specific enough that Troy's Claude can run it.
THE CHECKLIST (cleaned up from Troy's original):
Did we hit our call count for HVAC & Plumbing yesterday?
If no: cancellations, demand calls not booked same-day, reschedules, staffing
Staffing detail: calls per tech (Tech Performance Report → filter day → filter BU → Completed Jobs > 0 → total calls ÷ techs); idle vs working time (Idle Report → filter day → filter BU → export → idle hours ÷ working hours); overtime run; time to first call (Dispatch board arrival times, dispatch-to-arrival gap)
Booking % (Avoca Dashboard). Target 90%+
If under: calls to Avoca, callbacks within 1 min, same-day appointments offered, immediate callback on unbooked, how far out we're booking, service fee waiver when board not full or 10+, script usage, 8am–8pm framing (moves to 10pm on 5/1/26)
3-day call board full? Tomorrow 100%, 2 days 66%, 3 days 33% (including expected inbounds). If no: outbound 20 contacts/hr, texts via Chiirp or ST. Also: are tune-ups booked in or out of the 3-day board?
  DEFERRED (2026-07-15): the 3-day call board is on hold for now. Reason: it relies on ServiceTitan's Capacity endpoint, which returned 403 Forbidden — the "Sierra Claude Access" app does not have the capacity/dispatch scope. This also blocks the "tune-ups in/out of the board" question, which depends on the same endpoint.
  FIX WHEN WE COME BACK TO IT: (1) in Troy's login, add the capacity / dispatch READ scope to the Sierra Claude Access app; (2) reconnect the app to the tenant (Settings → Integrations → API Application Access); (3) CHECK whether the App Key changes after reconnecting — if it does, update secrets.json with the new appKey. Then re-run the probe against the capacity endpoint to confirm it returns 200.
  RESOLVED 2026-07-16 - built as M7 (a 14-day booked-calls CALENDAR, no capacity/fill%). See METRIC BUILD STATUS below. The whole "full %" framing was dropped as the wrong question (no real per-tech capacity limit).
  UPDATE 2026-07-16 - CAPACITY SCOPE NOT NEEDED after all. Boss built his board without it. Investigated: technician-shifts ARE populated forward (verified ~90 distinct techs/weekday, ~0 on weekends, out months ahead; startsOnOrAfter filter works, startsBefore ignored so client-filter the window). technicians carry businessUnitId, so capacity per day per BU = (# techs scheduled that day whose home BU = X) joined shift.technicianId -> technician.businessUnitId. Numerator (booked new-opp calls scheduled per day per BU) is computable like M1 booked. So "3-day board" IS buildable. THE ONE MISSING INPUT: calls-per-tech-per-day CAPACITY constant (no API field for it; capacity/ACP endpoint still 403). That must be a CONFIG value Troy sets (fits "targets from config"). Without it we can still show booked + techs-scheduled per day; the fill % needs the constant.
Booking rate on Angi, Schedule Pro, Avoca callbacks, LSA, Yelp
  FEASIBLE (investigated 2026-07-16): sources map to marketing CAMPAIGN CATEGORIES. /marketing/v2/.../campaigns has category{id,name}, source, medium, name. Categories seen: Yelp, Google LSA, Lead Aggregators (Angi lives here, plus Avoca campaigns), Google PPC, Google Business Profile, SEO, Social Media. crm/leads carry campaignId (428/429 populated), status (Converted/Dismissed/Open), and bookingId (present when booked). So booking rate per source = leads grouped by campaign->category, booked / total, over a period. NEEDS 3 DECISIONS before building: (a) source->campaign mapping (Angi = Lead-Aggregators campaigns whose name contains 'Angi'; Yelp = Yelp cat; LSA = Google LSA cat; Schedule Pro = booking source 'Scheduling Pro' / Web Scheduler campaigns; Avoca = Avoca-named campaigns); (b) what "booked" means (lead has bookingId, vs status=Converted - they differ: 249 vs 72 in 21d); (c) the period. AVOCA CAVEAT: Avoca's own answer->book funnel is external/Enterprise-gated (see Avoca note); via ST we can only show leads attributed to Avoca campaigns and their booked rate, NOT Avoca's call-handling %.
Maintenances booked next 14 days (currently 50 or less)
Club members left to run, HVAC + Plumbing daily (only run 10–20% in June/July)
WHERE WE GOT TO:
ServiceTitan Tenant ID: 1066404518 (not secret, safe to store)
Tested and failed — do not retry: my own ST login has no Settings access. Typing the Settings URL directly bounces back to the dashboard. Confirmed dead end.
Troy gave me his login. Through it: Settings → Integrations → API Application Access works.
An app called "Sierra Claude Access" already was made (App ID e86rkrgr55w4g), Read access to nearly everything.
Tested and failed — do not retry: "Connect New App" does not create apps. It only connects apps that already exist. Apps are created at developer.servicetitan.io first, then connected here.
DONE: App is created AND connected to the tenant. All four credential values are in hand — clientId, clientSecret, appKey, tenantId. They live in secrets.json (gitignored, never committed). Credentials no longer need to be generated.
CONFIRMED WORKING: credentials in secrets.json are verified. Ran test-connection.ps1 — token obtained, API call returned HTTP 200, and a real technician record came back from tenant 1066404518. The full chain (auth server → access token → authenticated API call → live data) works end-to-end.

BUSINESS UNIT MAPPING (pulled read-only from ServiceTitan 2026-07-15, 10 active units):
HVAC:
  337        HVAC - Install - AOR
  342817560  HVAC - Maintenance
  370        HVAC - Sales (NR)
  340802904  HVAC - Sales Costco (NR)
  333        HVAC - Service
Plumbing:
  595105985  Plumbing - Drains
  408662213  Plumbing - Install
  354        Plumbing - Maintenance
  353        Plumbing - Service
Exclude (not a trade):
  208554530  Inventory
DECIDED (call count): Troy wants a SEPARATE call count for EACH of the 10 business units, shown per-unit. Do NOT lump them into HVAC/Plumbing totals. (The HVAC/Plumbing grouping above is just for reference/mapping; the dashboard shows one call-count number per business unit.)
DECIDED (call definition, 2026-07-15): a job counts as a "call" (new opportunity) only if, on the JOB record (not the appointment): recallForId is empty AND warrantyId is empty AND the job type name does NOT match recall|warranty|part.*install (case-insensitive). Source: Oliver's boss, who already built a working ServiceTitan call board against this same tenant (his shorthand "SIE" = 1066404518, same tenant). We adopt his field-level opportunity filter. We do NOT adopt his board's separate exclusion of the Install BU (408662213) — that's specific to his install-less board; Troy wants all trade units reported, so Install stays in. Full spec in SPEC.md (M1); closes OQ #1.
DECIDED (booked + completed, 2026-07-15): show TWO call-count numbers per business unit — BOOKED and COMPLETED. Both use the same new-opportunity filter above. They count different cohorts, so they are NOT expected to match on a given day. Boss confirmed his board also shows both. Full spec in SPEC.md (M1); closes OQ #11.

DECIDED (2026-07-16, Troy answered the open questions):
  - BOOKED means SCHEDULED FOR the day (calls on the dispatch board that day), NOT booked-on/createdOn. Bucket by appointment start. THIS CHANGED M1 (was createdOn) — M1 rebuilt.
  - CANCELLATIONS (M2): date to the day SCHEDULED FOR SERVICE (appointment start = the dispatch-board cancel tray), NOT when cancelled. Also capture per cancellation: when it cancelled, why (reason), who cancelled. Verified live these ARE available: reason/time/user via jobs/{id}/canceled-log (reasonId, createdOn, createdById), reason name via job-cancel-reasons, user name via settings/employees. The job record itself has NO cancel fields.
  - CALLS PER TECH (M3): ONLY HVAC-Service (333) and Plumbing-Service (353) techs, two rows. Not installers. (MTD/YTD period denominator still undecided.)
  - OVERTIME (M4): day-before only; Service techs (333, 353) only; payroll lag acceptable since always looking back a day. (Double-time inclusion still to confirm.)
  - MAINTENANCES NEXT 14 DAYS (M5): club-MEMBERSHIP maintenances only; window anchored from today. (Source + count-basis still to confirm.)
  - CLUB MEMBERS LEFT TO RUN (M6): HVAC only for now; members with no completed COOLING maintenance in the last 16 months. Switches to heating in the fall — season/lookback/trade must be CONFIG values, not code. Plumbing later. (Which recurring-service/job types = cooling vs heating still needs a mapping.)
  Full detail + remaining open items in SPEC.md (M1-M6 + OPEN QUESTIONS).

DECIDED (2026-07-16 round 2, Troy):
  - M4 OVERTIME: keep total OT clock hours but SPLIT BY ACTIVITY TYPE (Idle, Driving, Training, job time, etc.) - one line each + total. Discover activities from the data. Rebuilt.
  - M5 MAINTENANCES NEXT 14 DAYS: count what's BOOKED ON THE CALENDAR (maintenance appointments, next 14 days, from today), NOT membership obligations. Purpose = see dead space to fill. Count visits; break out by day + trade. UNBLOCKED - built.
  - M6 COOLING vs HEATING: Troy says both exist as distinct job types in ST - investigate the job-types list and identify them (show Troy before building M6).
  - M2 CANCELLATIONS: 19 for July 15 CONFIRMED CORRECT -> M2 VERIFIED. Also add JOB TYPE to the per-cancellation detail (we already show who + why).

DECIDED (2026-07-16 round 3, Troy — rough-draft mode, not waiting for perfect definitions):
  - M5 MAINTENANCES: use ALL maintenance job types but SECTION the output (SAM Cooling, SAM Heating, HVAC Semi-Annual Tune-ups, Filter Changes, Plumbing Water Heater Maintenance, Plumbing Water Heater Tune-ups, Commercial). Semi-Annual Tune-ups included as their own section. 419-vs-50 gap is fine; sectioning lets Troy say what he means. Rebuilt.
  - M6 CLUB MEMBERS: UNBLOCKED, built. Cooling = ^SAM Cooling Service, heating = ^SAM Heating Service; season/lookback(16mo)/trade(HVAC) are config (fall switch = one-line). "Left to run" = active HVAC member with no completed cooling maintenance in last 16 months (completion-based set difference, customer-level).

DONE (2026-07-20/21 — full audit + frozen-day fix + Sierra rebrand + Cancellations/Calls UI):
  FULL DATA-SOURCE AUDIT (2026-07-20): every metric M1-M8 cross-checked LIVE against ServiceTitan (exact endpoint, fields, filter logic, and sample records). All 8 are mechanically sound - they compute what the code says. IMPORTANT: this is a mechanical audit, NOT Troy sign-off; M3-M8 are still NOT human-verified.
  AUDIT FINDINGS (flag to Troy - some numbers are solid, some rest on assumptions):
    - M1 "call count" INCLUDES maintenance/tune-up visits (SAM Cooling, water-heater service, etc.). The new-opportunity filter only drops recall/warranty/parts-install; every other job type counts, including maintenance. May not match Troy's mental model of a "call." DEFINITION question.
    - M4 OVERTIME: no OT pay-items are dated to FRIDAYS or SATURDAYS anywhere in the data (verified across 6+ weeks; startedOn confirms none classified OT on those days). So a Fri/Sat selected day shows 0 OT - indistinguishable from a real "no OT." Since M4 reports YESTERDAY, any Saturday/Sunday morning meeting reads 0. Likely a weekly payroll-posting cycle. NEEDS a payroll/Troy answer before M4's zeros can be trusted.
    - M5 MAINTENANCES: dashboard totals ~399 booked visits over 14 days vs Troy's "~50" expectation (~8x). Sections are provisional; Troy must say which sections count toward his number.
      RESOLVED 2026-07-24 (Troy): the "50" carries NO WEIGHT — it was never a target (config has none), just an expectation Oliver recorded. Troy wants the straight TOTAL maintenance visits booked over the next 14 days. Full count is CORRECT and now VERIFIED (502 on 2026-07-24). By BU: 342817560 HVAC-Maintenance 291 (SAM Cooling 288), 354 Plumbing-Maintenance 137, 333 HVAC-Service 63 (Semi-Annual Tune-ups 56 live here, not HVAC-Maint), 353 Plumbing-Service 11. Note M5 filters by job-TYPE (7 maintenance sections), NOT by business unit. No sectioning/target needed; sections + per-day stay as useful detail underneath.
    - M8 BOOKING BY SOURCE: "Other" (unmapped leads) is the LARGEST bucket, and Yelp = 0 leads in 30 days - confirm the source mappings. bookingId reads ~99% for Angi but 0% for LSA/Avoca (they book without a bookingId), so Booked UNDERCOUNTS LSA/Avoca; Converted is the truer signal for them.
  FROZEN-DAY FIX (resolves most of OQ #9): serve.ps1 was serving ANY cached past-day file blindly, so a day captured mid-afternoon (isToday=true, partial) was served as final - e.g. 2026-07-17 showed completed 112 when the real full day is 189. FIX: Build-Snapshot now stamps final=(date<today); serve.ps1's Get-SnapshotJson serves a past-day cache ONLY if final (has the final flag, OR legacy: isToday=false AND generatedAt >= that day's Pacific-midnight end), otherwise it recomputes on demand from the now-complete data and re-freezes. A partial is never served as final. Rebuilt 2026-07-16 and 2026-07-17 as final. Residual: the re-freeze is one-shot, so a backdated edit made after re-freeze isn't reflected until the next recompute (accepted).
  SIERRA REBRAND (dashboard.html, presentation only): dark theme -> Sierra LIGHT theme. White bg, dark-navy text (#12243b); brand blue #0a66b0 / gold #f4a522 / red #c42b28 (sampled from the logo + site CTA). Sierra Sam logo embedded as a base64 data-URI in the header (server only serves the one HTML file, so it's inlined). Poppins font w/ system fallback. Light-gray caveats DARKENED for contrast (normal #54607a, warnings dark-orange #b4540a) - both pass WCAG AA on white. Brand re-tint = 3 CSS vars at the top of the <style> block. Added .claude/launch.json (a browser-preview helper; harmless, does not affect the normal serve.ps1 run).
  CANCELLATIONS TAB (dashboard.html): added SUMMARY RANKINGS above the detail table - top CSRs by cancel count and top reasons by count, each ranked with a bar and clickable to filter. Added combinable/clearable FILTERS: reason, CSR, business unit, job type, and timing (same-day vs days-ahead, derived from cancelled-date vs scheduled-date). Live "showing X of Y" count. Rows with no cancel-log show "-" timing. Filters reset per day.
  CALLS TAB (dashboard.html): table -> TILES, one per business unit (all 9), grouped into labeled HVAC / Plumbing sections with per-section booked/completed subtotals. Booked is the hero number, completed secondary. Day total stays in the header.
  All four UI changes are PRESENTATION ONLY - the data + math layers and every other tab are untouched.

DONE (2026-07-21 — SILO / ROPP monthly metric M9 investigated + defined + standalone script built):
  CONTEXT: porting coworker John's HVAC-ROPP view (a frozen example dashboard, numbers hardcoded from CSV
  exports - NOT a live source of truth) onto our live ServiceTitan pipeline. We do NOT need to match his
  numbers; we need to be correct against live data.
  ROPP TAG: confirmed tagTypeId 962027 (name "ROPP"), via settings/v2/.../tag-types; jobs carry it in their
  tagTypeIds array. jpm/jobs honors a server-side tagTypeIds filter (unlike businessUnitIds). ROPP spans many
  BUs, so SILO is scoped by a technician ROSTER, not by tag alone.
  LOCKED DEFINITION (full detail in SPEC.md M9):
    - ROPP CALL = ROPP tag + HVAC Service(333)/Maintenance(342817560) + jobStatus=Completed (completedOn in
      the Pacific month) + new-opportunity filter (exclude recall/warranty/parts-install) + run by a roster
      tech (active appointment-assignment, matched by technicianName). Count every job, NO customer dedupe.
    - TGL = "Estimate ... TGL" job type, created in the month, attributed via jobGeneratedLeadSource.employeeId
      to a roster tech (employeeId = the turnover/generating tech, NOT soldById). MUST resolve INACTIVE
      employees too (active=false), else ~24% of ids don't resolve and the roster undercounts.
    - CONVERSION = TGLs / calls. MONTH BY MONTH (one month ~= 2 min of API calls; a long window is ~6x).
  DEFINITION ANALYSIS (what each lever does, dept-wide ROPP svc+maint, Jan1-Jul7 = 4533 base): exclude
    recall/warranty -84 (-1.9%); dedupe by customer+day -35 (-0.8%); dedupe by CUSTOMER -636 (-14%, REJECTED -
    those are legit separate visits); status=Completed is "ran" (InProgress/Hold negligible; Canceled = the
    cancel tray, a separate metric).
  API QUIRKS FOUND: (1) appointment-assignments IGNORES a technicianId filter (returns all) - attribution
    MUST be per-job by jobId. (2) settings/technicians + settings/employees default to ACTIVE ONLY - pull
    active=false too. (3) TGL->tech link lives in jobGeneratedLeadSource{employeeId,jobId}, populated ~99.7%.
  SCRIPT: get-silo-ropp.ps1 (standalone, dot-sources lib/st-common.ps1; -Month yyyy-MM, defaults to last full
    month). Fails loud. VERIFIED June 2026: SILO 831 calls / 400 TGLs / 48.1%; ~135s/month. Proven standalone
    first, THEN wired into the dashboard (see next block).
  ROSTER NOTE: 14 names locked (SPEC.md M9). "Dustin Romine" and "Alex Yakovchuk" are NOT in the active
    technician catalog but DO appear in assignment/lead data - matched by name. Alex showed only 1 call in June
    vs 303 across Jan-Jul: likely a role change / partial tenure = a ROSTER question for John, not a data bug.

DONE (2026-07-21 cont'd — SILO dashboard view + new-PC handoff guide):
  M9 IN THE DASHBOARD: added a SILO tab, wired to a SEPARATE monthly endpoint /api/silo?month=YYYY-MM (NOT part
    of the daily snapshot, so it never slows the day tabs). Uses a MONTH picker (type=month), not the daily date
    picker - the header swaps controls per tab. Month caching mirrors the frozen-day fix: a past month is
    computed ONCE and served instantly forever (final flag, data/silo-YYYY-MM.json); the current month refreshes
    at most every 6h. Fail-loud: compute error -> "COULD NOT LOAD" panel; a not-yet-computed month shows a
    spinner + "~2 min" note; never a fake number. New server bits: Build-SiloSnapshot + Get-Metric-SiloRopp in
    lib/metrics.ps1 (kept OUT of $METRIC_DEFS), Get-SiloJson + Test-SiloFinal + /api/silo route in serve.ps1.
  SILO VIEW REDESIGN (dark, John-style): the SILO view is a DARK analytical module (scoped under .silowrap) -
    hero conversion GAUGE (semicircular arc, red<48 / gold48-60 / blue>=60 tier zones, glowing value arc),
    big stat tiles (Calls / TGLs / Conversion), and a per-tech LEADERBOARD ranked by calls with gradient bars +
    medals. WHY DARK for this view only: gauges/bars pop far more on dark (why John built it dark), and it
    signals a deep-dive vs the light at-a-glance morning tabs. Kept coherent: same light header/logo/nav, Poppins
    font, Sierra blue/gold accents, month picker - a dark module INSIDE our app, not a separate app. Verified
    live June 2026 in-browser (gauge 48.1%, tiles 831/400/48.1%, 14-row leaderboard). All 4 UI tabs this session
    (rebrand, cancellations, calls tiles, SILO) are PRESENTATION ONLY - data/math layers untouched.
  HANDOFF GUIDE: SETUP-ON-NEW-PC.md - dead-simple, zero-coding steps to run the dashboard on another Windows PC
    (Troy's): copy the folder (NOT secrets.json), nothing to install (PowerShell is built in), enter the 4
    credentials fresh into secrets.json (never emailed), start with `powershell -ExecutionPolicy Bypass -File
    serve.ps1`, open http://localhost:8787, keep-alive/power settings, and troubleshooting. PREREQUISITE called
    out: a regular login CANNOT reach Settings -> Integrations -> API Application Access (Oliver's couldn't) -
    needs Troy's/an admin login, or the 4 values handed over directly.

DONE (2026-08-03 - Troy answered ALL 34 open definition questions; corrections + rebuilds. FULL REASONING
IN DECISIONS.md - this is the status summary only):
  TWO DATA-INTEGRITY CORRECTIONS (both mean previously-reported numbers were WRONG):
    - PAYROLL PAGING DEFECT: the gross-pay-items endpoint returns BYTE-IDENTICAL DUPLICATE ROWS across page
      boundaries at pageSize=300 SPECIFICALLY (200 and 2500 are clean - verified by repeated pulls: same
      totalCount, different row SET, OT counts swinging 619-1360). Server-side defect, not our paging code.
      M4 was reading at exactly 300. Fixed to 2500 (a work day fits one page; API cap 5000). 2026-07-15
      overtime 529.9 -> 380.9 hrs (-28%); HVAC-Svc 362 -> 250.9, Plmb-Svc 167.9 -> 130. Cross-validated:
      dashboard and standalone script now agree to 0.1 hr. ALSO FIXED the same 300 in get-overtime.ps1 and
      probe-overtime-lag.ps1 (both were inflating); probe's stale baseline moved out so it re-baselines clean.
      *** NEVER PAGE THIS TENANT AT 300. ***
    - M2 "19 vs 28" FULLY EXPLAINED (no residual): Troy's 19 counted cancelled JOBS, M2 counted cancelled
      VISITS (-2: two jobs cancelled while the visit stayed 'Done', so M2 never saw them -> M2 would have
      said 17 on the day). Then +11 recorded AFTER Troy looked, which file back onto 07-15 because a
      cancellation is dated to the day it was BOOKED FOR. TEN of those 11 were ONE admin sweep on 07-17
      (one user deleting ten duplicate "QA Crew Check" jobs in ~90 seconds, reason "Duplicate entry").
      CONSEQUENCE: a past day's cancellation count can rise INDEFINITELY. "Frozen past days" is false for M2.
  METRICS REBUILT (BUILT + verified):
    - M2 CANCELLATIONS rebuilt to 6 locked rules (reschedules excluded; one job = one cancellation; admin
      cleanup reasons excluded - Duplicate entry + Avoca Duplicate + 2 retired, every exclusion COUNTED and
      SHOWN on screen; counted as-of-now with an on-screen "NOT FINAL, can still rise" caveat; counts even
      when the visit was left 'Done' - fixed a real ~1-2/day undercount; a multi-day job counts ONCE on its
      first booked day). 2026-07-15: 28 -> 17. 2026-07-29: 29 -> 25 (later read 29 - D4 behaviour, live).
      NOTE: requires jobStatus='Canceled' AND an active cancel-log; this tenant NEVER deactivates cancel-log
      entries (31,553/31,553 active), so log-presence alone would wrongly count 9 jobs that COMPLETED on 07-15.
    - M3 CALLS PER TECH: denominator now the PRIMARY tech only (earliest-assigned; no primary flag exists in
      the data). EFFECT: ZERO - only 1 of 99 jobs on 07-15 had a second tech, and he was primary elsewhere.
      THE PREMISE DID NOT HOLD: ride-alongs were NOT inflating this. 73/31/2.4 was already correct.
    - M8 BOOKING BY SOURCE: grouping switched from campaign NAME matching to campaign CATEGORY, so new
      campaigns are picked up AUTOMATICALLY. Added Costco, SEO, Main Line Number, Google PPC, Texting,
      Outbound, Google Business Profile. "Other" 411 leads (69.5%) -> 35 (5.9%) over 30 days.
  YELP INVESTIGATED - NOT DARK, IT'S A BLIND SPOT: 152 calls to the Yelp tracking number and 66 Yelp-campaign
    JOBS in 90 days, continuing to date. But the last Yelp-attributed LEAD was 2026-03-03. Around early March
    Yelp traffic moved to a path where AVOCA BOOKS THE JOB DIRECTLY WITHOUT CREATING A LEAD (all 66 have no
    booking record and no lead). M8 reads only leads, so it correctly shows 0. *** LIKELY NOT YELP-SPECIFIC ***
    - any source Avoca books this way is invisible; probably explains LSA/Avoca showing Converted but 0 booked.
    NOT YET CHECKED whether other campaigns do the same. If they do, M8 may need rebuilding on JOBS, not leads.
  "PROBLEM FIXED ITSELF" ANALYSED (38.2% of all cancellations, 1,110 in 90 days - the largest reason):
    it is LARGELY A CATCH-ALL - only ~1 use in 10 matches the label. ~25% describe a reschedule. Five staff
    use it for >90% of everything they cancel while four equally-busy colleagues never use it once (one
    handled 295 cancellations without it). But it is NOT ticket-dumping: median 47h booking->cancel, same as
    every other reason, no end-of-shift spike, notes 100% filled in. Staff appear to select on the label's
    second half, "(CSR tried to save)". DECISION: LEFT COUNTED - it is mostly real lost work, just not what
    the label says. Revisit if Sierra adds a "Customer cancelled / will reschedule" reason.
  DISPATCH/ARRIVAL FEASIBILITY PROVEN (metric NOT built): actual dispatch AND arrival timestamps DO exist on
    a per-job event log, 100% populated on COMPLETED jobs (900/900 sampled; the ~86% overall figure is
    cancelled/hold jobs where no tech was ever dispatched - correct, not missing). Deterministic. Cost: one
    call per completed job (~100/day). *** API-COVERAGE.md IS WRONG - it says arrival is not exposed. ***
  UI: Demand tab SPLIT into two tabs (Call Board, Sources) - it overflowed 1080p once M8 grew to 13 sources.
    Both now measure ZERO overflow at 1920x1080; source table renders in two columns. PRE-EXISTING overflow
    still unfixed on Cancellations (~766px, bottom ~40% off-screen), SILO (~150px), Pipeline (~44px).
  CACHE: 8 stale day files (06-30, 07-15, 07-16, 07-17, 07-20, 07-21, 07-24, 07-27) held pre-change M8 output
    and were moved to backup so they recompute. NOTE for future metric changes: cached "final" days keep
    serving OLD definitions until cleared.

ALL 34 DEFINITION QUESTIONS ARE NOW ANSWERED (Troy, 2026-08-03). Every answer, its reasoning, and its
effect on the numbers is in DECISIONS.md. The list below is only what is NOT yet done.

DECIDED BUT NOT YET BUILT (the build queue - definitions are locked, code is not written):
  - M4 OVERTIME: show all-OT and JOB-ONLY OT side by side; show DOLLARS as well as hours; and SAY WHEN
    PAYROLL IS INCOMPLETE (the two most recent days carry ~half the entries of older days, and M4 reports
    YESTERDAY - so it systematically reads the least-complete day). Fail loud, do not show a silent low number.
  - M5 MAINTENANCES: 14-day window starts TOMORROW, not today (today is already booked and flatters it).
  - M6 CLUB MEMBERS: a member is a HOUSE/LOCATION, not a customer (today a customer with two properties
    counts once and vanishes from the list if either one ran). Season flips cooling->heating the LAST WEEK OF
    SEPTEMBER with NO HARD CUT - leftover cooling members must keep showing after the flip.
  - M7 CALL BOARD: keep weekends, but mark them NON-BUDGETED so lighter volume reads as expected, not a gap.
  - M9 SILO: derive the roster PER MONTH (it changes - Alex Yakovchuk stepped up to help manage in the busy
    season, hence 1 call in June vs 303 across the year). Adopt John's definition: a "call ran" = a COMPLETED
    job CARRYING the ROPP tag; no tag, or a tag management removed, does NOT count (this should also close
    most of the ~290/6mo gap vs his report). A tech who left mid-month still appears with a partial number.
  - DISPATCH/ARRIVAL (new metric, feasibility proven): clock starts at DISPATCH, not when the tech leaves -
    sitting-around time counts, DELIBERATELY, Troy wants to see it. On time = first call of the morning
    arriving before 8:30 when dispatched before 8:30. Time-to-first-call measured from first dispatch. MUST
    use nearest-pair-per-VISIT matching, not first-of-each-type (naive pairing produced 81h and 213h gaps).
  - OVERVIEW: the Maintenances panel shows the NEXT 3 DAYS as a small calendar so Troy can work the schedule.
  - RUNNING TOTALS (DTD/MTD/YTD): still not built. Anchoring is now DECIDED - a past date shows totals AS OF
    THAT DAY. M3's period denominator is also decided: the TYPICAL NUMBER WORKING PER DAY, not everyone who
    worked at any point.

STILL OPEN (genuinely unanswered):
  - M6: WHICH MEMBERSHIP TYPES COUNT AS HVAC. Still a GUESS, and it sets the size of the whole member base
    (9,633 active members / 1,998 left to run). Pull every membership type with active counts and have Troy
    identify them. DO NOT GUESS. Blocking M6 accuracy.
  - M8: do OTHER campaigns besides Yelp also bypass lead creation via Avoca? Not checked. If they do, M8 may
    need rebuilding on JOBS rather than leads. Potentially invalidates the metric.
  - BACKDATED ENTRIES / FROZEN DAYS: Troy decided a closed day SHOULD change when someone backdates an entry.
    NOT BUILT, and it CONTRADICTS the current design, which marks any past day final and serves it from cache
    forever. What breaks: (1) SPEED - past days are instant today; recomputing costs minutes on a cold pull
    (club members is the slow part) and a wall display polling every few minutes cannot afford it;
    (2) CONSISTENCY - Troy may act on a morning number that changes by afternoon (M2 now carries an on-screen
    "can still rise" caveat for exactly this; anything else made live needs the same); (3) "VERIFIED" numbers
    recorded in these docs stop being reproducible. RECOMMENDED: keep caching but RE-CHECK past days on a
    schedule instead of freezing permanently, and show when each number was last computed. DO NOT simply
    delete the freeze logic.
  - VERIFICATION with Troy still outstanding for M6 and M7 (M1/M2/M3/M4/M5/M8 definitions are now settled;
    M2/M3/M4 numbers changed on 2026-08-03 and Troy has not eyeballed the new ones).
  - DEPLOYMENT (unsolved, blocks real wall use): still on a personal laptop. Troy confirmed the wall display
    should be ALWAYS ON, which makes a dedicated always-on machine (mini-PC / the wall PC) with verified
    auto-start on boot a hard requirement, not a nice-to-have. SETUP-ON-NEW-PC.md covers installing it;
    picking and standing up that host is still open.
  - KNOWN UNFIXED: Cancellations tab overflows 1080p by ~766px (bottom ~40% off-screen), SILO ~150px,
    Pipeline ~44px. API-COVERAGE.md wrongly states arrival timestamps are unavailable. SPEC.md still carries
    the PRE-2026-08-03 definitions for M2, M3 and M4 - where it disagrees with DECISIONS.md, DECISIONS.md wins.

AVOCA: BLOCKED (as of 2026-07-16). Their API has what we need — /api/calls, /api/v1/bookings, and funnel analytics (covers booking % and booking-by-source). BUT those endpoints are ENTERPRISE-TIER ONLY, and Sierra's team is not on Enterprise. Someone has to ask Avoca to enable it. Scopes we'd need once enabled: read:calls, read:scheduler_analytics. NOT ACTIONABLE until Avoca turns on Enterprise access — do not spend time building Avoca metrics before then.

NEXT STEPS (in order):
DONE — app creation. Read-only scopes: Jobs, Appointments, Technicians, Calls, Bookings, Memberships, Performance, Reporting.
DONE — connected that app to tenant via Settings → Integrations → API Application Access. App Key and Client ID/Secret generated and in hand.
DONE — pulled one test API call. test-connection.ps1 ran successfully: token obtained, HTTP 200, real technician record returned from tenant 1066404518. Data comes back and looks right.
DONE — researched API coverage. API-COVERAGE.md = the pure technical-capability record: for every checklist item, whether the ServiceTitan API can provide it (POSSIBLE / PARTIAL / NOT POSSIBLE), which endpoint/fields, and what's missing. Verified with a live read-only probe on 2026-07-15. It carries NO decisions or deferrals — keep it that way.
DONE — wrote the spec for the POSSIBLE metrics. SPEC.md = the build spec + decision record for metrics: plain-English meaning, endpoint, exact fields, step-by-step calc, per-BU breakdown, DTD/MTD/YTD, edge cases, and an OPEN QUESTIONS list. Metrics specced: Call count (booked + completed), Cancellations, Calls per tech, Overtime, Maintenances next 14 days, Club members left to run. OQ #1 and #11 are closed; other OPEN QUESTIONS still need Troy/boss answers before those metrics are built.
   (Doc roles: DECISIONS.md = every business rule + WHY (read first). WHERE-WE-ARE.md = status. SPEC.md = how to build each metric. API-COVERAGE.md = what the API can/can't do. Keep them separate.)
METRIC BUILD STATUS (updated 2026-08-03 - see DECISIONS.md for the reasoning behind every rule):
  - M1 Call count (get-call-counts.ps1): BUILT. Definition SETTLED 2026-08-03 - maintenance visits DO count
    as calls; one job = one call even with several visits; booked and completed are separate numbers that
    are NOT meant to reconcile. No code change needed. STALE SAMPLE WARNING: this file previously recorded
    "booked 249 / completed 228" for 2026-07-15; a live pull on 2026-07-29 returned 232 / 229. Booked drifted
    -7%, not investigated. Do not treat the old sample as reproducible.
  - M2 Cancellations: REBUILT 2026-08-03 to six locked rules (see the DONE block above and DECISIONS.md).
    2026-07-15 = 17 (was 28). THE OLD "VERIFIED 19 (Troy, 2026-07-16)" NO LONGER REPRODUCES and is not a bug:
    the 19 counted cancelled JOBS while the metric counts cancelled VISITS, and 11 more cancellations were
    recorded after Troy looked (10 of them one admin duplicate-cleanup sweep). A past day's count keeps
    rising by design; the metric now says so on screen. Troy has NOT yet eyeballed the new number.
  - M3 Calls per tech: denominator changed 2026-08-03 to the PRIMARY tech only. NO EFFECT on the numbers -
    only 1 of 99 jobs on 2026-07-15 had a second tech assigned, and he was primary on another call. The
    "ride-alongs inflate this" premise DID NOT HOLD. 2026-07-15 still HVAC-Svc 73/31/2.4, Plmb-Svc 26/13/2.0.
  - M4 Overtime (get-overtime.ps1 + lib/metrics.ps1): PAGING DEFECT FIXED 2026-08-03 - every overtime figure
    recorded before that date is INFLATED ~28-39%. 2026-07-15 = 380.9 hrs total (was 529.9). Friday/Saturday
    zeros are CORRECT, not a bug: the payroll workweek starts FRIDAY (Troy confirmed), so nobody has crossed
    the weekly threshold on days 1-2 - a Sat/Sun morning meeting legitimately shows zero. STILL TO BUILD:
    job-only OT alongside all-OT, dollars as well as hours, and an incomplete-payroll warning.
  - M5 Maintenances next 14 days (get-maintenances-14d.ps1): REBUILT 2026-07-16 - SECTIONED by maintenance group + per-day dead-space table. VERIFIED 2026-07-24 (Troy): he wants the straight 14-day TOTAL booked; full count is correct (502 on 2026-07-24). The "~50" expectation was dropped as meaningless (never a target). Sections + per-day breakout remain as useful detail underneath the headline total.
  - M6 Club members left to run (get-club-members-to-run.ps1): BUILT 2026-07-16 - HVAC cooling, 16mo lookback, config-driven, completion-based. NOT verified.
  - M7 Call Board (lib/metrics.ps1 only): REVISED 2026-07-16 - now a 14-day CALENDAR of booked calls per day (HVAC-Service + Plumbing-Service), same visual as the M5 maintenance calendar. Light days = dashed holes = open room. Techs-scheduled shown as a small secondary per-day footnote. FILL % / CAPACITY DROPPED ENTIRELY (no per-tech capacity limit exists, so "full" was the wrong question) - removed callsPerTechPerDay from config.json and the Fill % column. Booked + techs are live. NOT verified.
  - M8 Booking Rate by Source (lib/metrics.ps1 only): REBUILT 2026-08-03 - grouping is now by campaign
    CATEGORY, not name-matching, so new campaigns are picked up AUTOMATICALLY. 12 named sources + Other.
    "Other" fell from 411 leads (69.5%) to 35 (5.9%) over 30 days. 30-day period CONFIRMED by Troy.
    *** THE BIG CAVEAT: this metric reads LEADS ONLY, and Avoca books some jobs WITHOUT creating a lead.
    Yelp proves it - 152 calls and 66 Yelp jobs in 90 days but ZERO leads since 2026-03-03, so M8 shows 0
    for a channel Sierra is actively paying for and that is actively working. This also likely explains
    LSA/Avoca showing Converted>0 with 0 booked. NOT CHECKED whether other campaigns do the same. If they
    do, M8 needs rebuilding on JOBS rather than leads. *** Troy's instruction 2026-08-03: note it, do not
    change the logic yet.
  - CONFIG: config.json exists at project root as the future targets/goals placeholder. callsPerTechPerDay was REMOVED (M7 no longer uses capacity). Currently unused; kept for when targets are added. (Get-DashConfig in st-common.ps1 still exists for that future use.)
  - DASHBOARD: new "Demand" tab added (6 tabs total: Overview, Calls, Cancellations, Staffing, Pipeline, Demand) showing M7 + M8. Data/math/presentation layers still cleanly separated; adding M7/M8 needed only a metric function + registry entry + a tab render (no rewrite).

BUILD NOTES / API QUIRKS discovered 2026-07-16 (keep for future metrics):
  - jpm/jobs BU filter RESOLVED: plural `businessUnitIds` is IGNORED (returns all). Singular `businessUnitId` works but takes ONE id only (comma-list 400s; repeated takes the first). There is NO multi-BU server filter. So for multi-unit metrics we fetch the day's jobs and filter client-side (fewer calls than looping per-BU anyway). The dead `businessUnitIds` param was removed from get-call-counts.ps1 and get-calls-per-tech.ps1; use singular `businessUnitId` only if a metric ever targets exactly one unit. Correctness never depended on the server filter (all scripts client-verify businessUnitId).
  - payroll gross-pay-items: `startedOnOrAfter` is IGNORED (returns all ~2M). The working work-day filter is `dateOnOrAfter`/`dateOnOrBefore` on the `date` field, which is a calendar date at UTC MIDNIGHT (a local work date) - so payroll is bucketed by plain calendar date, NOT the Pacific-07:00 window used by jobs/appointments.
  - Overtime pay-type value is the literal 'Overtime' in paidTimeType; no separate DoubleTime value seen.
  - M4 OT FIELD UNIT CONFIRMED: `paidDurationHours` is decimal HOURS (verified: equals endedOn-startedOn for each row). The separate `amount` field is dollars. IMPORTANT for M4 interpretation: paidTimeType='Overtime' rows include NON-JOB activities (Idle, Driving, Training) - these are OT clock hours with amount=0. So M4's "OT hours" = total overtime clock hours across all activities, which is why the daily total is large. Confirm with Troy this is the "overtime run" he wants (vs. only job/wrench OT, or OT dollars).

NEXT STEP — M2/M3/M4 need Troy's sanity-check (none marked verified). Then: M5/M6 once their open questions (below) are answered. One at a time; fail loud; flag caveats.
Build ST metrics first, then layer in Avoca.

DASHBOARD (rough draft BUILT 2026-07-16) - a local web page, three separated layers:
  - lib/st-common.ps1  = DATA layer (auth, paging, timezone, shared catalogs). Nothing metric-specific.
  - lib/metrics.ps1     = MATH layer. One Get-Metric-* function per metric returning a "block" (tables+notes+status). Add a metric = add a function + register in $METRIC_DEFS. Build-Snapshot assembles all six with per-metric timestamps + error isolation (one metric failing does NOT blank the others).
  - serve.ps1 + dashboard.html = PRESENTATION layer. serve.ps1 is a local HttpListener (http://localhost:8787) serving the page + /api/metrics?date=YYYY-MM-DD (JSON). Sierra LIGHT theme (white bg, dark-navy text, brand blue/gold/red, Sierra Sam logo, Poppins font; rebranded 2026-07-20 from the old dark/Apple look), big text, date picker. TABBED (redesigned 2026-07-16 for Troy's TV, which he can drive): Overview (default always-on = six headline numbers, no tables), Calls (M1 as TILES, one per BU, grouped into HVAC/Plumbing sections, booked = hero), Cancellations (M2: summary rankings [top CSRs, top reasons] + combinable/clearable filters over the detail table), Staffing (M3 + M4), Pipeline (M5 + M6), Demand (M7 + M8). Each tab fits one 1080p screen, no scroll (cancellations detail capped at 16 rows w/ "+N more"). Overview is curated (headline numbers extracted client-side per metric id); detail tabs are grouped by the morning-meeting flow. NOTE: the math layer stays generic; adding a metric to the Overview needs a small HTML addition (detail tabs are per-group).
  - refresh.ps1 = pulls a date to data/<date>.json (pre-warm / -Loop keeps today live).
  Behavior: date picker; TODAY auto-refreshes (page polls every 3 min; server recomputes when its cache >5 min old); PAST days are frozen, but served ONLY if the cache is FINAL (computed after the Pacific day ended) - a stale mid-day partial is recomputed on demand and re-frozen (2026-07-20 fix; see the DONE section). Every metric shows "pulled X ago"; a failed metric shows "COULD NOT LOAD" in place - never a stale/fake number. Caveats shown inline (e.g. overtime includes idle/driving/training).
  NO targets/goals (by design). Blocks have room to add a target field later from a config file without a rewrite.
  M5 (maintenances) and M6 (club members) are "as of pull time", NOT tied to the selected day (they're forward/backlog) - noted on-screen.
  HOW TO RUN (laptop): 1) double-check secrets.json present; 2) in PowerShell in this folder run  .\serve.ps1  ; 3) open http://localhost:8787 . Optional live wall: also run  .\refresh.ps1 -Loop  in a second window. First view of a not-yet-pulled day takes a couple minutes (M6 is the slow one); after that it's cached/instant. data\2026-07-15.json is pre-warmed for the Troy demo.
  PERF NOTE: M6 loops ~30 cooling job types over 16 months; M3 makes ~1 call per completed job. A cold full pull is a few minutes. Fine for a laptop draft; optimize when moved to a real host.

RULES:
Fail loud, never guess. If data is missing or an API call fails, the dashboard says so on screen. It never shows a made-up or stale number. On a wall display this matters double — Troy will be reading it from ten feet away and won't know a number is three hours old unless it tells him.
Don't hard-code targets. (Targets are a LATER add-on — when added, read them from a config file so Troy can change a number without touching code. The dashboard's core job is showing raw numbers, not judging them.)
One step at a time, confirm each piece works before moving on.