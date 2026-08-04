# ============================================================================
#  lib/metrics.ps1  --  MATH LAYER (layer 2)
#  One function per metric. Each returns a "block":
#    @{ id; title; status='ok'|'error'; error; notes=@(); tables=@( @{subtitle;columns;rows;footer} ) }
#  Add a metric = add a Get-Metric-* function and register it in $script:METRIC_DEFS.
#  Build-Snapshot assembles all blocks with per-metric timestamps + error isolation.
# ============================================================================
. (Join-Path $PSScriptRoot 'st-common.ps1')

# ---------- M1: Call count (booked scheduled-for-day + completed), per BU ----------
function Get-Metric-CallCounts($Ctx, [datetime]$Date) {
    $w = Get-PacDayWindow $Ctx $Date
    $jt = Get-JobTypeMap $Ctx
    $completed = Invoke-StPaged $Ctx "/jpm/v2/tenant/$($Ctx.Tenant)/jobs" @{ completedOnOrAfter=$w.StartIso; completedBefore=$w.EndIso; jobStatus='Completed' }
    $appts     = Invoke-StPaged $Ctx "/jpm/v2/tenant/$($Ctx.Tenant)/appointments" @{ startsOnOrAfter=$w.StartIso; startsBefore=$w.EndIso }
    $booked=@{}; $comp=@{}
    foreach ($id in $script:BU_NAMES.Keys) { $booked[$id]=0; $comp[$id]=0 }
    foreach ($job in $completed) {
        $bu = "$($job.businessUnitId)"; if (-not $script:BU_NAMES.Contains($bu)) { continue }
        if ($job.jobStatus -ne 'Completed') { continue }
        $t = Parse-Utc $job.completedOn
        if ($t -ge $w.StartUtc -and $t -lt $w.EndUtc) { if (Test-NewOpportunity $job $jt) { $comp[$bu]++ } }
    }
    $sched = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($a in $appts) {
        if ($a.status -eq 'Canceled') { continue }
        $t = Parse-Utc $a.start
        if (-not ($t -ge $w.StartUtc -and $t -lt $w.EndUtc)) { continue }
        if (Is-EmptyVal $a.jobId) { continue }
        [void]$sched.Add("$($a.jobId)")
    }
    if ($sched.Count -gt 0) {
        $jm = Get-JobsByIds $Ctx $sched
        foreach ($jid in $sched) {
            $job = $jm[$jid]; $bu = "$($job.businessUnitId)"; if (-not $script:BU_NAMES.Contains($bu)) { continue }
            if (Test-NewOpportunity $job $jt) { $booked[$bu]++ }
        }
    }
    $rows=@(); $tb=0; $tc=0
    foreach ($id in $script:BU_NAMES.Keys) { $rows += ,@($script:BU_NAMES[$id], $booked[$id], $comp[$id]); $tb+=$booked[$id]; $tc+=$comp[$id] }
    @{ id='call-counts'; title='Call Count - new opportunities'; status='ok'; error=$null;
       notes=@('Booked = calls SCHEDULED FOR the day. Completed = calls finished that day. Different jobs; not expected to match.');
       tables=@( @{ subtitle=''; columns=@('Business Unit','Booked','Completed'); rows=$rows; footer=("TOTAL   Booked $tb    Completed $tc") } ) }
}

# ============================================================================
#  M2: Cancellations (cancel tray), per BU + detail
#  DEFINITION LOCKED 2026-07-29 by the business owner after the 2026-07-15 forensic review
#  (GM verified 19 on 07-16; a live pull returned 28). One cancellation for the selected
#  Pacific day = a JOB that
#    (a) had at least one appointment SCHEDULED IN that Pacific day, AND
#    (b) is genuinely cancelled now  -> jobStatus = 'Canceled' AND it carries an active
#        cancel-log entry. This is what separates a real cancellation from a RESCHEDULE (D1):
#        a rescheduled visit leaves the job un-cancelled (verified over 10 days: zero cases
#        of a Canceled appointment on a job that was not itself Canceled), AND
#    (c) is counted ONCE per job, however many of its visits that day were cancelled (D2), AND
#    (d) does NOT have an administrative-cleanup cancel reason (D3, list below), AND
#    (e) counts REGARDLESS of that day's appointment status - 'Canceled' OR 'Done' (D5).
#        FIXES A REAL UNDERCOUNT: the old version keyed off APPOINTMENT status only, so a job
#        cancelled after its visit had already been marked Done was missed entirely
#        (2 such on 2026-07-15, ~1-2 on a typical day).
#  D4: the count is AS OF THIS PULL, not as of the day itself - late cancellations date back
#      onto the day they were scheduled for, so the number can still rise. Deliberately NO
#      as-of cutoff; the on-screen note says so, so nobody reads yesterday as final.
#  WHY jobStatus is required and not just the cancel-log: this tenant NEVER sets a cancel-log
#  entry inactive (31,553/31,553 active all-time), so an old log entry survives on a job that
#  was later reinstated and run. On 2026-07-15 nine jobs COMPLETED that day still carried an
#  active cancel-log from an earlier cancellation - log-presence alone would have counted those
#  nine as cancellations. jobStatus='Canceled' is what makes "still cancelled" true today.
#  D6 (added 2026-08-03, business owner decision): a cancelled job counts ONCE ONLY, on the
#  FIRST Pacific day it ever had a visit booked - not on every day it happened to have a visit
#  scheduled. A 3-day install cancelled mid-job must appear on day 1 only, not days 2-3.
#  "First day booked" = the earliest appointment START across ALL of the job's appointments
#  (fetched job-wide, not limited to this selected day), converted to its Pacific calendar date.
#  We deliberately use ALL appointments regardless of status (Canceled or not) to find that
#  earliest start: a cancelled visit still reflects when the job was ORIGINALLY booked, and
#  using only non-cancelled appointments would let the anchor day shift around as visits get
#  cancelled one by one - the same job could then wrongly appear to have a different "first
#  day" on different pulls. The anchor must be stable no matter which visits are later cancelled.
# ============================================================================

# --- D3: ADMINISTRATIVE-CLEANUP CANCEL REASONS -> NOT counted as cancellations -------------
# Keyed by ServiceTitan job-cancel-reason ID (ids are stable; names can be re-typed).
# Rule applied: exclude ONLY reasons that plainly mean a duplicate / erroneous RECORD, never
# reasons that mean the customer stopped wanting the work. Deliberately NOT excluded:
# 'Problem fixed itself (CSR tried to save)' - the customer genuinely no longer needed the
# visit, which is real lost work, not a data-entry error.
# Every exclusion is COUNTED and shown on screen (see the notes below) so it is auditable,
# never a silent drop.
# COULD MOVE TO CONFIG: this list is a business rule, not math. If the owner wants to edit it
# without touching code, move it to config.json (read via Get-DashConfig in lib/st-common.ps1)
# and fall back to this list when the config key is absent.
$script:CANCEL_REASONS_ADMIN_CLEANUP = [ordered]@{
    # -- in active use --
    '102'       = 'Duplicate entry'                 # duplicate job record; the 07-17 sweep of 10 "QA Crew Check" dupes
    '656703594' = 'Avoca Duplicate'                 # duplicate booked by the Avoca answering service
    # -- legacy / inactive reasons (0 uses in the last 90 days; listed so old days behave the same) --
    '403340016' = 'History call clean up (legacy)'  # bulk record clean-up, retired 2025-06
    '398228702' = 'Reschedule (legacy)'             # excluded on D1 grounds: a reschedule is not lost work
}

function Get-Metric-Cancellations($Ctx, [datetime]$Date) {
    $w = Get-PacDayWindow $Ctx $Date
    $jt = Get-JobTypeMap $Ctx; $reasonMap = Get-CancelReasonMap $Ctx; $userMap = Get-UserMap $Ctx

    # every appointment scheduled in the Pacific day, ANY status (D5 needs 'Done' ones too)
    $appts = Invoke-StPaged $Ctx "/jpm/v2/tenant/$($Ctx.Tenant)/appointments" @{ startsOnOrAfter=$w.StartIso; startsBefore=$w.EndIso }
    $apptsByJob = @{}
    foreach ($a in $appts) {
        $t = Parse-Utc $a.start
        if (-not ($t -ge $w.StartUtc -and $t -lt $w.EndUtc)) { continue }
        if (Is-EmptyVal $a.jobId) { continue }
        $jid = "$($a.jobId)"
        if (-not $apptsByJob.ContainsKey($jid)) { $apptsByJob[$jid] = New-Object System.Collections.ArrayList }
        [void]$apptsByJob[$jid].Add($a)
    }

    $counts=@{}; foreach ($id in $script:BU_NAMES.Keys) { $counts[$id]=0 }
    $hits=New-Object System.Collections.ArrayList; $tot=0
    $exclAdmin=0; $exclAdminBy=[ordered]@{}   # D3 exclusions, and the reason mix behind them
    $exclResched=0                            # D1: cancelled visit on a job that is not cancelled
    $exclNoLog=0                              # jobStatus Canceled but no cancel-log at all (0 of 1122 checked)
    $dedupeSaved=0                            # D2: extra cancelled visits on a job already counted
    $exclNotFirstDay=0                        # D6: job's first-ever booked day is not this selected day

    if ($apptsByJob.Count -gt 0) {
        # job records for EVERY job on the board that day - the only way to see a job that is
        # cancelled while its visit still reads 'Done' (D5). ~6-7 batched id calls for a full day.
        $jm = Get-JobsByIds $Ctx @($apptsByJob.Keys)
        foreach ($jid in $apptsByJob.Keys) {
            $job = $jm[$jid]; $bu = "$($job.businessUnitId)"
            if (-not $script:BU_NAMES.Contains($bu)) { continue }        # Inventory / non-trade unit
            if ($null -eq $job.PSObject.Properties['jobStatus']) { throw "job $jid is missing field 'jobStatus'" }
            $dayAppts = @($apptsByJob[$jid] | Sort-Object { Parse-Utc $_.start })
            $cancAppts = @($dayAppts | Where-Object { $_.status -eq 'Canceled' })
            $isCancJob = ($job.jobStatus -eq 'Canceled')

            # candidate = some visit that day was cancelled, OR the job itself is cancelled (D5)
            if (-not $isCancJob) { $exclResched += $cancAppts.Count; continue }                 # D1

            $log = Invoke-StPaged $Ctx "/jpm/v2/tenant/$($Ctx.Tenant)/jobs/$jid/canceled-log"
            $entry = $log | Where-Object { $_.active } | Sort-Object { Parse-Utc $_.createdOn } | Select-Object -Last 1
            if (-not $entry) { $exclNoLog++; continue }                                        # D1 (no cancel-log = not a real cancellation)

            $rid = "$($entry.reasonId)"
            $reason = if ($entry.reasonId -and $reasonMap.ContainsKey($rid)) { $reasonMap[$rid] } else { "reason $rid" }
            if ($script:CANCEL_REASONS_ADMIN_CLEANUP.Contains($rid)) {                         # D3
                $exclAdmin++
                if (-not $exclAdminBy.Contains($reason)) { $exclAdminBy[$reason] = 0 }
                $exclAdminBy[$reason] = $exclAdminBy[$reason] + 1
                continue
            }

            # D6: only count this job on the FIRST Pacific day it ever had a visit booked.
            # Pull EVERY appointment on the job (any status - see D6 comment above the function
            # block for why) and anchor on the earliest start. Only fetched for jobs that have
            # already survived D1/D3 (genuinely cancelled, not admin-cleanup), which keeps this
            # extra query small - not one per appointment scheduled that day.
            $allAppts = Invoke-StPaged $Ctx "/jpm/v2/tenant/$($Ctx.Tenant)/appointments" @{ jobId=$jid }
            if ($allAppts.Count -eq 0) { throw "job $jid is cancelled with a cancel-log but has zero appointments" }
            $earliest = $allAppts | Sort-Object { Parse-Utc $_.start } | Select-Object -First 1
            $firstDayPac = ([TimeZoneInfo]::ConvertTimeFromUtc((Parse-Utc $earliest.start), $Ctx.Pac)).Date
            if ($firstDayPac -ne $Date.Date) { $exclNotFirstDay++; continue }

            # counted: once per job, however many of its visits that day were cancelled (D2)
            if ($cancAppts.Count -gt 1) { $dedupeSaved += ($cancAppts.Count - 1) }
            $counts[$bu]++; $tot++
            $jtName = if ($jt.ContainsKey("$($job.jobTypeId)")) { $jt["$($job.jobTypeId)"] } else { "jobType $($job.jobTypeId)" }
            $by = if ($entry.createdById -and $userMap.ContainsKey("$($entry.createdById)")) { $userMap["$($entry.createdById)"] } else { "user $($entry.createdById)" }
            # scheduled time shown = the cancelled visit if there is one, else that day's visit (D5 rows)
            $shownAppt = if ($cancAppts.Count -gt 0) { $cancAppts[0] } else { $dayAppts[0] }
            $schedStr = To-PacStr $Ctx $shownAppt.start
            [void]$hits.Add([pscustomobject]@{ sched=$schedStr; bu=$script:BU_NAMES[$bu]
                row=@($script:BU_NAMES[$bu], $jtName, $schedStr, (To-PacStr $Ctx $entry.createdOn), $reason, $by) })
        }
    }

    $rows=@()
    foreach ($id in $script:BU_NAMES.Keys) { $rows += ,@($script:BU_NAMES[$id], $counts[$id]) }
    # Stable, readable detail order: by scheduled time, then unit. (We now walk JOBS, not
    # appointments, so hash order would otherwise shuffle the table between pulls.)
    # NOTE: sort the record objects, never the row arrays themselves - piping a row array through
    # Sort-Object PSObject-wraps it and ConvertTo-Json then emits {"value":[...],"Count":6}
    # instead of a plain array, which breaks the dashboard's detail table.
    $detail=@()
    foreach ($h in @($hits | Sort-Object sched, bu)) { $detail += ,$h.row }

    $notes = @(
        'Dated to the day the call was scheduled for service (the dispatch-board cancel tray), not the day someone pressed cancel. Detail: job type, when cancelled, reason, who.',
        'One job = one cancellation, counted ONCE on the FIRST Pacific day it ever had a visit booked (a multi-day job cancelled mid-way shows on day 1 only, not later days). Counted whether that day''s visit reads Canceled or Done - a job cancelled after its visit was marked Done still counts. A cancelled visit that was only RESCHEDULED does not count; only jobs that are genuinely cancelled do.',
        'NOT FINAL - CAVEAT: this is the count AS OF THIS PULL. Cancellations recorded later still date back onto the day the work was scheduled for, so this number CAN STILL RISE. Do not read yesterday''s count as final.'
    )
    if ($exclAdmin -gt 0) {
        $mix = (@($exclAdminBy.Keys | ForEach-Object { "$_ x$($exclAdminBy[$_])" }) -join ', ')
        $notes += "EXCLUDED as administrative cleanup, not lost work: $exclAdmin on this day ($mix). These are duplicate / data-entry records. Excluded reasons: $((@($script:CANCEL_REASONS_ADMIN_CLEANUP.Values)) -join ', ')."
    } else {
        $notes += "EXCLUDED as administrative cleanup, not lost work: 0 on this day. Excluded reasons: $((@($script:CANCEL_REASONS_ADMIN_CLEANUP.Values)) -join ', ')."
    }
    if ($exclResched -gt 0) { $notes += "Not counted: $exclResched cancelled visit(s) whose job is not cancelled - rescheduled work, not lost work." }
    if ($exclNotFirstDay -gt 0) { $notes += "Not counted here: $exclNotFirstDay cancelled job(s) that had a visit booked this day, but whose FIRST-EVER booked day was earlier - counted there instead (one job counts once, on its first booked day)." }
    if ($dedupeSaved -gt 0) { $notes += "Not counted: $dedupeSaved extra cancelled visit(s) on jobs already counted once (one job = one cancellation)." }
    if ($exclNoLog -gt 0) { $notes += "CAVEAT: $exclNoLog cancelled job(s) had no cancel-log entry and were left out (no recorded reason - cannot be told apart from a reschedule)." }

    @{ id='cancellations'; title='Cancellations - cancel tray'; status='ok'; error=$null;
       notes=$notes;
       tables=@(
         @{ subtitle='By business unit'; columns=@('Business Unit','Canceled'); rows=$rows; footer=("TOTAL   $tot") },
         @{ subtitle='Detail'; columns=@('Business Unit','Job Type','Scheduled','Cancelled','Reason','By'); rows=$detail; footer='' }
       ) }
}

# ---------- Shared: job -> PRIMARY technician id (used by M3 Calls-per-Tech and M10 Dispatch & Arrival) ----------
# DECIDED 2026-07-29 (Troy/business owner, see M3 comment below for the full investigation): the
# PRIMARY technician on a job is the one with the active appointment-assignment with the EARLIEST
# assignedOn; ties broken by lowest technicianId (reproducible run to run). No explicit
# primary/lead flag exists on appointment-assignments, so this rule is the sole source of truth
# for "which tech is this job's real technician" anywhere in the dashboard - reuse it, don't
# reinvent a second primary-tech rule elsewhere (M10 dispatch/arrival attribution relies on this).
# appointment-assignments ignores a jobId LIST / date filter (SPEC.md / WHERE-WE-ARE.md) - it must
# be queried per job. Returns jobId(string) -> technicianId(string), or $null if the job has no
# resolvable active assignment (caller must treat that as an anomaly, not a silent drop).
# Resilience (2026-08-03): a per-job appointment-assignments fetch failure must NOT throw the
# whole metric - it is treated exactly like "no resolvable active assignment" ($m[$jidStr] = $null),
# which every caller (M3, M10) already handles as an anomaly/skip, not a silent drop. Callers that
# want to know HOW MANY lookups actually failed (vs. legitimately having zero active assignments)
# can inspect the optional $script:LastPrimaryTechMapFailures list this function populates.
function Get-JobPrimaryTechMap($Ctx, $jobIds) {
    $m = @{}
    $script:LastPrimaryTechMapFailures = New-Object System.Collections.ArrayList
    foreach ($jid in $jobIds) {
        $jidStr = "$jid"
        try {
            $assigns = Invoke-StPaged $Ctx "/dispatch/v2/tenant/$($Ctx.Tenant)/appointment-assignments" @{ jobId=$jidStr }
        } catch {
            [void]$script:LastPrimaryTechMapFailures.Add($jidStr)
            $m[$jidStr] = $null
            continue
        }
        $active = @($assigns | Where-Object { $_.active -and -not (Is-EmptyVal $_.technicianId) })
        if ($active.Count -eq 0) { $m[$jidStr] = $null; continue }
        $primary = $active | Sort-Object { Parse-Utc $_.assignedOn }, { [long]$_.technicianId } | Select-Object -First 1
        $m[$jidStr] = "$($primary.technicianId)"
    }
    $m
}

# ---------- M3: Calls per tech (Service units only) ----------
function Get-Metric-CallsPerTech($Ctx, [datetime]$Date) {
    $w = Get-PacDayWindow $Ctx $Date; $jt = Get-JobTypeMap $Ctx
    $svc = [ordered]@{ '333'='HVAC - Service'; '353'='Plumbing - Service' }
    $completed = Invoke-StPaged $Ctx "/jpm/v2/tenant/$($Ctx.Tenant)/jobs" @{ completedOnOrAfter=$w.StartIso; completedBefore=$w.EndIso; jobStatus='Completed' }
    $jobsByBu=@{}; foreach ($id in $svc.Keys) { $jobsByBu[$id]=New-Object System.Collections.ArrayList }
    foreach ($job in $completed) {
        $bu="$($job.businessUnitId)"; if (-not $svc.Contains($bu)) { continue }
        if ($job.jobStatus -ne 'Completed') { continue }
        $t=Parse-Utc $job.completedOn
        if ($t -ge $w.StartUtc -and $t -lt $w.EndUtc) { if (Test-NewOpportunity $job $jt) { [void]$jobsByBu[$bu].Add($job) } }
    }
    # DENOMINATOR (DECIDED 2026-07-29 - Troy/business owner): count only the technician RUNNING the
    # call (the primary), not every body sent on the job (helpers/apprentices/ride-alongs must not
    # inflate the tech count). Investigated live on 2026-07-15 (HVAC-Service + Plumbing-Service,
    # completed jobs): an appointment-assignment record carries id, technicianId, technicianName,
    # assignedById, assignedOn, status, isPaused, jobId, appointmentId, createdOn, modifiedOn, active
    # - NO explicit primary/lead/first-assignee flag exists. Chosen rule (per SPEC.md M3 edge cases,
    # "count only the primary assignment per job"): for each job, the PRIMARY is the active assignment
    # with the EARLIEST assignedOn; ties broken by lowest technicianId, so the result is reproducible
    # run to run. Denominator = distinct primary technicianIds across the unit's completed jobs that day.
    # (Only 1 of the 99 jobs checked on 2026-07-15 had >1 assigned tech, so this mostly matches the old rule.)
    $allJobIds = New-Object System.Collections.ArrayList
    foreach ($id in $svc.Keys) { foreach ($job in $jobsByBu[$id]) { [void]$allJobIds.Add("$($job.id)") } }
    $primaryMap = Get-JobPrimaryTechMap $Ctx $allJobIds
    $techByBu=@{}; foreach ($id in $svc.Keys) { $techByBu[$id]=New-Object 'System.Collections.Generic.HashSet[string]' }
    foreach ($id in $svc.Keys) {
        foreach ($job in $jobsByBu[$id]) {
            $tid = $primaryMap["$($job.id)"]
            if ($null -eq $tid) { continue }
            [void]$techByBu[$id].Add($tid)
        }
    }
    $rows=@()
    foreach ($id in $svc.Keys) {
        $n=$jobsByBu[$id].Count; $d=$techByBu[$id].Count
        $ratio = if ($d -gt 0) { "{0:N1}" -f ($n/$d) } else { '-' }
        $rows += ,@($svc[$id], $n, $d, $ratio)
    }
    # OQ #3 / SPEC M3 STILL OPEN (do not build yet): for MTD/YTD, the denominator must be the TYPICAL
    # number working per day (average of daily headcounts over the period), NOT every distinct primary
    # tech who ran a call at any point in the period - a month-long distinct-tech count would badly
    # understate techs-per-day. Whoever builds MTD/YTD for this metric must use the daily-average rule.
    @{ id='calls-per-tech'; title='Calls per Tech - Service'; status='ok'; error=$null;
       notes=@('Service units only. Techs = distinct PRIMARY technician per job (earliest-assigned active tech runs the call); helpers/ride-alongs on the same job do not add to the count. Single day only.');
       tables=@( @{ subtitle=''; columns=@('Business Unit','Completed Calls','Techs','Calls/Tech'); rows=$rows; footer='' } ) }
}

# ---------- M4: Overtime hours (Service techs, by activity) ----------
# M4.1: payroll workweek runs Friday..Thursday (confirmed 2026-08-03, see DECISIONS.md).
# Returns the Pacific-calendar-date of the Friday that starts the workweek containing $d.
function Get-WorkweekFriday([datetime]$d) {
    # DayOfWeek: Sun=0 Mon=1 ... Fri=5 Sat=6. Days since the most recent Friday (0 if d is itself Friday).
    $daysSinceFri = (([int]$d.DayOfWeek) - 5 + 7) % 7
    $d.Date.AddDays(-$daysSinceFri)
}

function Get-Metric-Overtime($Ctx, [datetime]$Date) {
    $dayStr = $Date.ToString('yyyy-MM-dd')
    # pageSize MUST stay large enough that a work day fits in ONE page. This endpoint returns exact
    # DUPLICATE rows across page boundaries at pageSize=300 (verified: same day, repeated pulls, same
    # totalCount but OT counts swinging 619-1360 and ~26% byte-identical dupes). pageSize=200 and 2500
    # both return zero dupes; 2500 keeps a day single-page. API cap is 5000. Do not lower this.
    # Pull ONCE at pageSize 2500 and reuse the same array for every sub-calculation below
    # (all-hours OT, job-only OT, and the payroll-completeness item count all come from this one pull).
    $items = Invoke-StPaged $Ctx "/payroll/v2/tenant/$($Ctx.Tenant)/gross-pay-items" @{ dateOnOrAfter="${dayStr}T00:00:00Z"; dateOnOrBefore="${dayStr}T23:59:59Z" } 2500
    $svc=@('HVAC - Service','Plumbing - Service')
    $byAct=@{}; $unitTot=@{}; $unitJobTot=@{}; foreach ($u in $svc) { $unitTot[$u]=0.0; $unitJobTot[$u]=0.0 }
    foreach ($it in $items) {
        if ($it.paidTimeType -ne 'Overtime') { continue }
        $d=[DateTime]::Parse($it.date, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
        if ($d.ToString('yyyy-MM-dd') -ne $dayStr) { continue }
        $bu="$($it.payoutBusinessUnitName)"; if ($svc -notcontains $bu) { continue }
        $hrs=0.0; [void][double]::TryParse("$($it.paidDurationHours)", [ref]$hrs)
        $act = if ([string]::IsNullOrWhiteSpace([string]$it.activity)) { '(no activity)' } else { "$($it.activity)" }
        if (-not $byAct.ContainsKey($act)) { $byAct[$act]=@{}; foreach ($u in $svc) { $byAct[$act][$u]=0.0 } }
        $byAct[$act][$bu]+=$hrs; $unitTot[$bu]+=$hrs
        # M4.3: job-only overtime - same row set, further restricted to jobId != 0 (a real job attached).
        $hasJob = (-not (Is-EmptyVal $it.jobId))
        if ($hasJob) { $unitJobTot[$bu]+=$hrs }
    }
    $rows=@()
    foreach ($a in ($byAct.Keys | Sort-Object)) {
        $h1=$byAct[$a]['HVAC - Service']; $h2=$byAct[$a]['Plumbing - Service']
        $rows += ,@($a, [math]::Round($h1,1), [math]::Round($h2,1), [math]::Round($h1+$h2,1))
    }
    if ($rows.Count -eq 0) { $rows += ,@('(no overtime)', 0, 0, 0) }
    $foot = "TOTAL   HVAC-Service {0}    Plumbing-Service {1}" -f [math]::Round($unitTot['HVAC - Service'],1), [math]::Round($unitTot['Plumbing - Service'],1)

    # M4.3 table: all-hours vs job-only vs non-job (all minus job-only), by unit + total.
    $allH=$unitTot['HVAC - Service']; $allP=$unitTot['Plumbing - Service']
    $jobH=$unitJobTot['HVAC - Service']; $jobP=$unitJobTot['Plumbing - Service']
    $nonJobH=$allH-$jobH; $nonJobP=$allP-$jobP
    $jobRows = @(
        ,@('Overtime (all hours)',      [math]::Round($allH,1),    [math]::Round($allP,1),    [math]::Round($allH+$allP,1))
        ,@('Overtime (on jobs only)',   [math]::Round($jobH,1),    [math]::Round($jobP,1),    [math]::Round($jobH+$jobP,1))
        ,@('Overtime (non-job: idle/driving/training)', [math]::Round($nonJobH,1), [math]::Round($nonJobP,1), [math]::Round($nonJobH+$nonJobP,1))
    )

    # ---- M4.5: incomplete-payroll detection (fail-loud warnings, math layer decides IF, not HOW rendered) ----
    $cfg = Get-DashConfig
    $threshold = 0.80; $lookbackWeeks = 4
    if ($cfg -and $cfg.payrollCompletenessThreshold) { $threshold = [double]$cfg.payrollCompletenessThreshold }
    if ($cfg -and $cfg.payrollCompletenessLookbackWeeks) { $lookbackWeeks = [int]$cfg.payrollCompletenessLookbackWeeks }

    $warnings = @()

    # (a) workweek-in-progress: payroll week is Fri..Thu. If the displayed day's workweek is the
    # SAME workweek containing today (Pacific), the week is still open and totals will keep rising.
    $todayPac = Get-TodayPac $Ctx.Pac
    $weekFriOfDay   = Get-WorkweekFriday $Date.Date
    $weekFriOfToday = Get-WorkweekFriday $todayPac
    if ($weekFriOfDay -eq $weekFriOfToday) {
        $warnings += @{ type='workweek-in-progress'; day=$dayStr;
            message = "Overtime workweek still in progress (started Fri $($weekFriOfDay.ToString('MM/dd'))) - totals will keep rising until the week closes." }
    }

    # (b) partial-day payroll: compare THIS day's TOTAL gross-pay-item count (all paidTimeTypes,
    # all BUs - the whole feed volume, using the SAME pull above) against the median total count
    # for the SAME weekday over the prior N completed weeks (day minus 7/14/21/28).
    $todayCount = $items.Count
    $priorCounts = @()
    for ($w=1; $w -le $lookbackWeeks; $w++) {
        $pd = $Date.Date.AddDays(-7*$w); $pdStr = $pd.ToString('yyyy-MM-dd')
        $pItems = Invoke-StPaged $Ctx "/payroll/v2/tenant/$($Ctx.Tenant)/gross-pay-items" @{ dateOnOrAfter="${pdStr}T00:00:00Z"; dateOnOrBefore="${pdStr}T23:59:59Z" } 2500
        $priorCounts += $pItems.Count
    }
    $median = $null
    if ($priorCounts.Count -gt 0) {
        $sorted = @($priorCounts | Sort-Object)
        $mid = [math]::Floor(($sorted.Count-1)/2)
        $median = if ($sorted.Count % 2 -eq 1) { $sorted[$mid] } else { ($sorted[$mid] + $sorted[$mid+1]) / 2.0 }
    }
    $ratio = $null
    if ($median -and $median -gt 0) {
        $ratio = $todayCount / $median
        if ($ratio -lt $threshold) {
            $pct = [math]::Round($ratio*100,0)
            $weekdayName = $Date.ToString('dddd')
            $warnings += @{ type='partial-day-payroll'; day=$dayStr; pct=$pct; ratio=$ratio; itemCount=$todayCount; medianCount=$median;
                message = "Payroll for $weekdayName $($Date.ToString('MM/dd')) looks incomplete - only $pct% of a typical $weekdayName. Overtime is likely understated." }
        }
    }

    # Warnings are surfaced ONLY via the dedicated 'warnings' field, not duplicated into notes -
    # the presentation layer (dashboard.html) renders warnings as a prominent banner; notes stay
    # for the routine caveats below.
    $notes=@('TOTAL overtime CLOCK HOURS - INCLUDES non-job time (Idle, Driving, Training), not just job time.','Grouped by tech payout unit. Payroll figure for the selected day.')

    @{ id='overtime'; title='Overtime hours - Service, by activity'; status='ok'; error=$null;
       notes=$notes; warnings=$warnings;
       tables=@(
         @{ subtitle='By activity'; columns=@('Activity','HVAC-Service','Plumbing-Service','Total'); rows=$rows; footer=$foot },
         @{ subtitle='All hours vs. job-only'; columns=@('','HVAC-Service','Plumbing-Service','Total'); rows=$jobRows; footer='' }
       ) }
}

# ---------- M10: Dispatch & Arrival (Service units only) ----------
# Locked pairing algorithm (do not reinterpret): per job, take ONLY 'Technician Dispatched' and
# 'Technician Arrived' history events (drop 'Technician Dispatch Canceled' and everything else),
# sorted chronologically. Walk with a LIFO stack of open dispatches: a Dispatched event pushes its
# time; an Arrived event pops the most-recently-pushed open dispatch and emits a matched pair
# (dispatch time, arrival time, jobId). Anything left over at the end of a job (an open dispatch
# with no arrival, or an arrival with nothing to pop) is an ANOMALY - counted and surfaced, never
# silently dropped (fail-loud).
# TECH IDENTITY (fixed 2026-08-03): the 'Technician Dispatched' event's employeeId is the OFFICE
# DISPATCHER who clicked dispatch (role=Dispatch), NOT the technician who ran the call - using it
# collapsed a whole day onto the handful of dispatchers on shift. Each matched pair is instead
# attributed to its JOB's PRIMARY TECHNICIAN via Get-JobPrimaryTechMap - the exact same rule M3
# (Calls per Tech) uses (earliest-assigned active appointment-assignment, ties by lowest tech id).
# A job with no resolvable primary technician is an ANOMALY (unattributed), not a silent drop.
function Get-Metric-DispatchArrival($Ctx, [datetime]$Date) {
    $w = Get-PacDayWindow $Ctx $Date
    $dayStr = $Date.ToString('yyyy-MM-dd')
    $svc = @('333','353')   # HVAC-Service, Plumbing-Service ONLY (server ignores BU filter on jobs - client-filter)
    $jobs = Invoke-StPaged $Ctx "/jpm/v2/tenant/$($Ctx.Tenant)/jobs" @{ completedOnOrAfter=$w.StartIso; completedOnOrBefore=$w.EndIso; jobStatus='Completed' } 2500
    $svcJobs = New-Object System.Collections.ArrayList
    foreach ($job in $jobs) {
        $bu = "$($job.businessUnitId)"; if ($svc -notcontains $bu) { continue }
        if ($job.jobStatus -ne 'Completed') { continue }
        $t = Parse-Utc $job.completedOn
        if ($t -ge $w.StartUtc -and $t -lt $w.EndUtc) { [void]$svcJobs.Add($job) }
    }
    # id->name INCLUDING inactive technicians/employees (~24% of ids otherwise fail to resolve -
    # same catalog helper used by M-Silo; Get-UserMap alone is active-only and undercounts here too).
    $idName = Get-SiloIdNameMap $Ctx
    $pairs = New-Object System.Collections.ArrayList     # @{ jobId; dispatchUtc; arrivalUtc; gapMin }
    $anomalyCount = 0
    $anomalyNotes = New-Object System.Collections.ArrayList
    # Resilience (2026-08-03): a single job's history fetch failing (transient error, or the
    # response missing the 'history' field) must NOT blank the whole tile - skip that job, count
    # it, and keep going. Only escalate to a hard failure below if the skip rate is systemic
    # (see SKIPPED-JOB THRESHOLD after the loop) - a blip should degrade gracefully, not error out.
    $skippedJobs = New-Object System.Collections.ArrayList   # @{ jobId; reason }

    foreach ($job in $svcJobs) {
        $jid = "$($job.id)"
        # NOTE: this endpoint's response shape is { "history": [...] } (no data/hasMore/paging
        # envelope like the rest of the API), so Invoke-StPaged (which requires a 'data' field)
        # does not apply here - call it directly, matching the precedent in Get-Metric-SiloRopp
        # for appointment-assignments. A job's event log is small; no paging is needed.
        $histUrl = "$script:ApiBase/jpm/v2/tenant/$($Ctx.Tenant)/jobs/$jid/history"
        try { $histResp = Invoke-RestMethod -Method Get -Uri $histUrl -Headers $Ctx.Headers }
        catch {
            $st = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'n/a' }
            [void]$skippedJobs.Add(@{ jobId=$jid; reason="HTTP $st" })
            continue
        }
        if ($null -eq $histResp.PSObject.Properties['history']) {
            [void]$skippedJobs.Add(@{ jobId=$jid; reason="response had no 'history' field" })
            continue
        }
        $hist = @($histResp.history)
        $evts = @($hist | Where-Object { $_.eventType -eq 'Technician Dispatched' -or $_.eventType -eq 'Technician Arrived' } | Sort-Object { Parse-Utc $_.date })
        $stack = New-Object System.Collections.ArrayList
        foreach ($e in $evts) {
            if ($e.eventType -eq 'Technician Dispatched') {
                [void]$stack.Add(@{ date = (Parse-Utc $e.date) })
            } else {
                if ($stack.Count -eq 0) {
                    $anomalyCount++; [void]$anomalyNotes.Add("job $jid`: arrival with no open dispatch to match")
                    continue
                }
                $d = $stack[$stack.Count-1]; $stack.RemoveAt($stack.Count-1)
                $arrUtc = Parse-Utc $e.date
                [void]$pairs.Add(@{ jobId=$jid; dispatchUtc=$d.date; arrivalUtc=$arrUtc; gapMin=($arrUtc-$d.date).TotalMinutes })
            }
        }
        if ($stack.Count -gt 0) {
            $anomalyCount += $stack.Count
            [void]$anomalyNotes.Add("job $jid`: $($stack.Count) dispatch(es) with no matching arrival")
        }
    }

    # HARD-FAIL only when the history-fetch problem is systemic, not a blip: every job failed,
    # or more than 25% of jobs were unfetchable. A single transient failure (or a handful) should
    # degrade gracefully instead (see skippedJobs handling below) - fail-loud is for real outages,
    # not noise. Threshold (25%) is a judgment call, not from config.json (it's a robustness
    # tripwire, not a business target).
    $totalJobs = $svcJobs.Count
    if ($totalJobs -gt 0 -and $skippedJobs.Count -eq $totalJobs) {
        throw "Dispatch & Arrival: history fetch failed for ALL $totalJobs completed service job(s) - cannot compute anything for $dayStr."
    }
    if ($totalJobs -gt 0 -and ($skippedJobs.Count / [double]$totalJobs) -gt 0.25) {
        $pctBad = [math]::Round(100.0*$skippedJobs.Count/$totalJobs,1)
        throw "Dispatch & Arrival: history fetch failed for $($skippedJobs.Count) of $totalJobs completed service jobs ($pctBad%) for $dayStr - failure rate too high to trust the remaining data."
    }

    $n = $pairs.Count
    $avgGap = if ($n -gt 0) { ($pairs | ForEach-Object { $_.gapMin } | Measure-Object -Average).Average } else { $null }

    # Attribute each matched pair to its JOB's PRIMARY TECHNICIAN (see comment above the function) -
    # never the dispatching employee. One lookup per distinct job that produced a matched pair
    # (jobs with zero pairs need no lookup).
    $distinctJobIds = @($pairs | ForEach-Object { $_.jobId } | Select-Object -Unique)
    $primaryMap = if ($distinctJobIds.Count -gt 0) { Get-JobPrimaryTechMap $Ctx $distinctJobIds } else { @{} }

    # On-time %: group ALL matched pairs for the day by PRIMARY technician id;
    # each tech's "first call" = the pair with the earliest Pacific dispatch time.
    $byTech = @{}
    foreach ($p in $pairs) {
        $tid = $primaryMap["$($p.jobId)"]
        if ($null -eq $tid -or (Is-EmptyVal $tid)) {
            $anomalyCount++; [void]$anomalyNotes.Add("job $($p.jobId): matched pair has no resolvable primary technician - unattributed")
            continue
        }
        if (-not $byTech.ContainsKey($tid)) { $byTech[$tid] = New-Object System.Collections.ArrayList }
        [void]$byTech[$tid].Add($p)
    }
    $cutoff = New-TimeSpan -Hours 8 -Minutes 30
    $allTechs = $byTech.Keys.Count
    $qualified = 0; $onTime = 0
    $techRows = New-Object System.Collections.ArrayList
    foreach ($tid in $byTech.Keys) {
        $first = @($byTech[$tid] | Sort-Object { $_.dispatchUtc })[0]
        $dispPac = [TimeZoneInfo]::ConvertTimeFromUtc($first.dispatchUtc, $Ctx.Pac)
        $arrPac  = [TimeZoneInfo]::ConvertTimeFromUtc($first.arrivalUtc, $Ctx.Pac)
        $isQual = $dispPac.TimeOfDay -lt $cutoff
        $isOnTime = $isQual -and ($arrPac.TimeOfDay -lt $cutoff)
        if ($isQual) { $qualified++; if ($isOnTime) { $onTime++ } }
        $name = if ($idName.ContainsKey($tid)) { $idName[$tid] } else { "tech $tid" }
        [void]$techRows.Add([pscustomobject]@{ dispPac=$dispPac; row=@($name, $dispPac.ToString('HH:mm'), $arrPac.ToString('HH:mm'), $(if($isQual){'yes'}else{'no'}), $(if($isQual){$(if($isOnTime){'yes'}else{'no'})}else{'-'}) ) })
    }
    $onTimePct = if ($qualified -gt 0) { [math]::Round(100.0*$onTime/$qualified,1) } else { $null }
    $avgGapStr = if ($n -gt 0) { "{0:N1}" -f $avgGap } else { '-' }
    $onTimeStr = if ($qualified -gt 0) { "{0:N1}%" -f $onTimePct } else { '-' }

    $summaryRows = @(
        ,@('Average dispatch to arrival (minutes)', $avgGapStr)
        ,@('Matched dispatch/arrival pairs', $n)
        ,@('Anomalies (unmatched dispatch/arrival, or unattributed to a primary tech)', $anomalyCount)
        ,@('Techs dispatched before 8:30 (of all techs with a matched call)', "$qualified of $allTechs")
        ,@('On-time % (first call, arrival also before 8:30)', $onTimeStr)
        ,@('On-time count', "$onTime of $qualified")
    )
    $techDetailRows = @()
    foreach ($tr in @($techRows | Sort-Object dispPac)) { $techDetailRows += ,$tr.row }

    $notes = @(
        'Service units only (HVAC-Service, Plumbing-Service). Pairing: chronological Dispatched/Arrived events per job, LIFO-matched; Dispatch Canceled events are dropped. Times come from the dispatch/arrival events; TECH IDENTITY comes from the job''s PRIMARY TECHNICIAN (same rule as Calls per Tech: earliest-assigned active appointment-assignment) - never the dispatch event''s employeeId, which is the office dispatcher, not the technician.',
        'On-time %: for each technician, look only at their FIRST call of the day (earliest dispatch). Denominator = techs whose first-call dispatch was before 8:30 AM Pacific. Numerator = of those, how many arrived before 8:30 AM Pacific.',
        'Anomalies = a dispatch with no arrival, an arrival with no open dispatch to match, or a matched pair whose job has no resolvable primary technician - never silently dropped; counted above.'
    )
    if ($anomalyCount -gt 0) { $notes += "Anomaly detail: $((@($anomalyNotes) | Select-Object -First 8) -join '; ')$(if($anomalyNotes.Count -gt 8){' ...'})" }

    $warnings = @()
    if ($skippedJobs.Count -gt 0) {
        $sample = (@($skippedJobs) | Select-Object -First 5 | ForEach-Object { "$($_.jobId) ($($_.reason))" }) -join ', '
        $skipMsg = "$($skippedJobs.Count) of $totalJobs jobs' history could not be fetched and were left out - dispatch/arrival figures are based on the other $($totalJobs - $skippedJobs.Count). Examples: $sample$(if($skippedJobs.Count -gt 5){' ...'})"
        $notes += $skipMsg
        $warnings += @{ type='partial-data'; day=$dayStr; message = $skipMsg }
    }
    $todayPac = Get-TodayPac $Ctx.Pac
    if ($Date.Date -eq $todayPac.Date) {
        $warnings += @{ type='day-in-progress'; day=$dayStr;
            message = 'Selected day still in progress - dispatch/arrival is only meaningful once the day is done.' }
    }

    @{ id='dispatch-arrival'; title='Dispatch & Arrival - Service'; status='ok'; error=$null;
       notes=$notes; warnings=$warnings;
       tables=@(
         @{ subtitle='Summary'; columns=@('Metric','Value'); rows=$summaryRows; footer='' },
         @{ subtitle='By technician (first call of the day)'; columns=@('Technician','First Dispatch (Pac)','First Arrival (Pac)','Qualified (<8:30)','On-time'); rows=$techDetailRows; footer='' }
       ) }
}

$script:MAINT_SECTIONS = @(
    @{ Name='SAM Cooling (HVAC)';            Patterns=@('^SAM Cooling Service') },
    @{ Name='SAM Heating (HVAC)';            Patterns=@('^SAM Heating Service') },
    @{ Name='HVAC Semi-Annual Tune-ups';     Patterns=@('^Semi Annual Tune-up') },
    @{ Name='Filter Changes';                Patterns=@('^Filter Change') },
    @{ Name='Plumbing WH Maintenance (SAM)'; Patterns=@('^Plumbing SAM .*Water Heater Service') },
    @{ Name='Plumbing WH Tune-ups';          Patterns=@('Water Heater Tune-up') },
    @{ Name='Commercial Maintenance';        Patterns=@('^Commercial Cooling/Heating Maintenance') }
)
function Get-MaintSection($name) {
    foreach ($s in $script:MAINT_SECTIONS) { foreach ($p in $s.Patterns) { if ($name -match $p) { return $s.Name } } }
    return $null
}

# ---------- M5: Maintenances booked next 14 days (always from tomorrow) ----------
function Get-Metric-Maint14($Ctx, [datetime]$Date) {
    $jt = Get-JobTypeMap $Ctx
    $today = Get-TodayPac $Ctx.Pac; $windowStart = $today.AddDays(1); $endDay = $windowStart.AddDays(14)
    $sUtc=[TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($windowStart,'Unspecified'),$Ctx.Pac)
    $eUtc=[TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($endDay,'Unspecified'),$Ctx.Pac)
    $appts = Invoke-StPaged $Ctx "/jpm/v2/tenant/$($Ctx.Tenant)/appointments" @{ startsOnOrAfter=$sUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ"); startsBefore=$eUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ") }
    $byJob=@{}
    foreach ($a in $appts) {
        if ($a.status -eq 'Canceled') { continue }
        $t=Parse-Utc $a.start; if (-not ($t -ge $sUtc -and $t -lt $eUtc)) { continue }
        if (Is-EmptyVal $a.jobId) { continue }
        $jid="$($a.jobId)"; $pd=([TimeZoneInfo]::ConvertTimeFromUtc($t,$Ctx.Pac)).ToString('yyyy-MM-dd')
        if (-not $byJob.ContainsKey($jid)) { $byJob[$jid]=New-Object System.Collections.ArrayList }
        [void]$byJob[$jid].Add($pd)
    }
    $order = $script:MAINT_SECTIONS | ForEach-Object { $_.Name }
    $secCount=@{}; foreach ($n in $order) { $secCount[$n]=0 }
    $days = 0..13 | ForEach-Object { $windowStart.AddDays($_).ToString('yyyy-MM-dd') }
    $cH=@{};$cP=@{};$cO=@{}; foreach ($ds in $days) { $cH[$ds]=0;$cP[$ds]=0;$cO[$ds]=0 }
    if ($byJob.Count -gt 0) {
        $jm = Get-JobsByIds $Ctx ($byJob.Keys)
        foreach ($jid in $byJob.Keys) {
            $job=$jm[$jid]; $name = if ($jt.ContainsKey("$($job.jobTypeId)")) { $jt["$($job.jobTypeId)"] } else { $null }
            if (-not $name) { continue }
            $sec = Get-MaintSection $name; if (-not $sec) { continue }
            $bu="$($job.businessUnitId)"
            foreach ($pd in $byJob[$jid]) {
                if (-not $cH.ContainsKey($pd)) { continue }
                $secCount[$sec]++
                if ($script:HVAC_BUS -contains $bu) { $cH[$pd]++ } elseif ($script:PLMB_BUS -contains $bu) { $cP[$pd]++ } else { $cO[$pd]++ }
            }
        }
    }
    $secRows=@(); $grand=0
    foreach ($n in $order) { $secRows += ,@($n, $secCount[$n]); $grand+=$secCount[$n] }
    $dayRows=@()
    foreach ($ds in $days) { $dayRows += ,@($ds, $cH[$ds], $cP[$ds], ($cH[$ds]+$cP[$ds]+$cO[$ds])) }
    @{ id='maint-14d'; title='Maintenances booked - next 14 days (starting tomorrow)'; status='ok'; error=$null;
       notes=@('Window starts TOMORROW (Pacific), not today, and runs 14 days from there. Today is excluded. As of the pull time (forward-looking; not tied to the selected day). Booked appointments. Sections are provisional.');
       tables=@(
         @{ subtitle='By section (14-day totals)'; columns=@('Section','Visits'); rows=$secRows; footer=("GRAND TOTAL   $grand") },
         @{ subtitle='By day (dead space)'; columns=@('Date','HVAC','Plumbing','Total'); rows=$dayRows; footer='' }
       ) }
}

# ---------- M6: Club members left to run (always as of now) ----------
function Get-Metric-ClubMembers($Ctx, [datetime]$Date) {
    $season='Cooling'; $lookback=16    # CONFIG (fall switch: 'Heating')
    $seasonPat = @{ 'Cooling'='^SAM Cooling Service'; 'Heating'='^SAM Heating Service' }[$season]
    $jt = Get-JobTypeMap $Ctx
    $coolIds=@(); foreach ($id in $jt.Keys) { if ($jt[$id] -match $seasonPat) { $coolIds += $id } }
    $mtIds = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($mt in (Invoke-StPaged $Ctx "/memberships/v2/tenant/$($Ctx.Tenant)/membership-types")) { if ($mt.name -match '^SAM Membership') { [void]$mtIds.Add("$($mt.id)") } }
    $members = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($m in (Invoke-StPaged $Ctx "/memberships/v2/tenant/$($Ctx.Tenant)/memberships" @{ status='Active' })) {
        if ($mtIds.Contains("$($m.membershipTypeId)") -and -not (Is-EmptyVal $m.customerId)) { [void]$members.Add("$($m.customerId)") }
    }
    $today = Get-TodayPac $Ctx.Pac; $cut = $today.AddMonths(-$lookback)
    $cutIso = ([TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($cut,'Unspecified'),$Ctx.Pac)).ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
    $ran = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($tid in $coolIds) {
        foreach ($j in (Invoke-StPaged $Ctx "/jpm/v2/tenant/$($Ctx.Tenant)/jobs" @{ jobStatus='Completed'; completedOnOrAfter=$cutIso; jobTypeId=$tid })) {
            if (-not (Is-EmptyVal $j.customerId)) { [void]$ran.Add("$($j.customerId)") }
        }
    }
    $ranAmong=0; foreach ($c in $members) { if ($ran.Contains($c)) { $ranAmong++ } }
    $left = $members.Count - $ranAmong
    $pct = if ($members.Count -gt 0) { "{0:N1}%" -f (100.0*$left/$members.Count) } else { 'n/a' }
    @{ id='club-members'; title=("Club Members Left to Run - $season (HVAC)"); status='ok'; error=$null;
       notes=@("As of pull time. Active residential SAM members with no completed $season maintenance in last $lookback months. Customer-level.");
       tables=@( @{ subtitle=''; columns=@('Metric','Value'); rows=@( ,@('Active HVAC club members', $members.Count) ; ,@("Ran $season in last $lookback mo", $ranAmong) ; ,@('LEFT TO RUN', ("$left  ($pct)")) ); footer='' } ) }
}

# ---------- M7: Call board - booked calls per day, next 14 days (calendar view) ----------
function Get-Metric-CallBoard($Ctx, [datetime]$Date) {
    $jt = Get-JobTypeMap $Ctx; $techBU = Get-TechBUMap $Ctx
    $svc = @('333','353')   # HVAC-Service, Plumbing-Service
    $today = Get-TodayPac $Ctx.Pac; $endDay = $today.AddDays(14)
    $sUtc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($today,'Unspecified'),$Ctx.Pac)
    $eUtc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($endDay,'Unspecified'),$Ctx.Pac)
    $sIso = $sUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ"); $eIso = $eUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
    $days = 0..13 | ForEach-Object { $today.AddDays($_) }
    $dayKeys = @(); foreach ($dd in $days) { $dayKeys += $dd.ToString('yyyy-MM-dd') }

    # booked new-opportunity calls scheduled per day, split HVAC-Service / Plumbing-Service
    $appts = Invoke-StPaged $Ctx "/jpm/v2/tenant/$($Ctx.Tenant)/appointments" @{ startsOnOrAfter=$sIso; startsBefore=$eIso }
    $byJob = @{}
    foreach ($a in $appts) {
        if ($a.status -eq 'Canceled') { continue }
        $t = Parse-Utc $a.start; if (-not ($t -ge $sUtc -and $t -lt $eUtc)) { continue }
        if (Is-EmptyVal $a.jobId) { continue }
        $jid="$($a.jobId)"; $pd=([TimeZoneInfo]::ConvertTimeFromUtc($t,$Ctx.Pac)).ToString('yyyy-MM-dd')
        if (-not $byJob.ContainsKey($jid)) { $byJob[$jid]=New-Object System.Collections.ArrayList }
        [void]$byJob[$jid].Add($pd)
    }
    $hv=@{}; $pl=@{}; foreach ($k in $dayKeys) { $hv[$k]=0; $pl[$k]=0 }
    if ($byJob.Count -gt 0) {
        $jm = Get-JobsByIds $Ctx ($byJob.Keys)
        foreach ($jid in $byJob.Keys) {
            $job=$jm[$jid]; $bu="$($job.businessUnitId)"; if ($svc -notcontains $bu) { continue }
            if (-not (Test-NewOpportunity $job $jt)) { continue }
            $seen=@{}
            foreach ($pd in $byJob[$jid]) {
                if ($hv.ContainsKey($pd) -and -not $seen.ContainsKey($pd)) {
                    if ($bu -eq '333') { $hv[$pd]++ } else { $pl[$pd]++ }
                    $seen[$pd]=$true
                }
            }
        }
    }

    # technicians scheduled per day (service units) - secondary context
    $shifts = Invoke-StPaged $Ctx "/dispatch/v2/tenant/$($Ctx.Tenant)/technician-shifts" @{ startsOnOrAfter=$sIso }   # startsBefore ignored by API; client-filter
    $techByDay=@{}; foreach ($k in $dayKeys) { $techByDay[$k]=New-Object 'System.Collections.Generic.HashSet[string]' }
    foreach ($sh in $shifts) {
        if (-not $sh.active) { continue }
        $t = Parse-Utc $sh.start; if (-not ($t -ge $sUtc -and $t -lt $eUtc)) { continue }
        $pd=([TimeZoneInfo]::ConvertTimeFromUtc($t,$Ctx.Pac)).ToString('yyyy-MM-dd')
        $tid="$($sh.technicianId)"; $bu=$techBU[$tid]
        if ($null -eq $bu -or $svc -notcontains $bu) { continue }
        if ($techByDay.ContainsKey($pd)) { [void]$techByDay[$pd].Add($tid) }
    }

    # one calendar-source table: Date, HVAC-Service, Plumbing-Service, Total booked, Techs (secondary)
    $rows=@(); $grand=0
    foreach ($dd in $days) {
        $k=$dd.ToString('yyyy-MM-dd'); $h=$hv[$k]; $p=$pl[$k]; $tot=$h+$p; $tc=$techByDay[$k].Count
        $rows += ,@($k, $h, $p, $tot, $tc); $grand += $tot
    }
    @{ id='call-board'; title='Call Board - booked calls, next 14 days'; status='ok'; error=$null;
       notes=@('Booked = new-opportunity calls SCHEDULED for that day (HVAC-Service + Plumbing-Service). Light days show as thin cells - that is open room on the board.',
               'Techs = service technicians scheduled that day (secondary context). As of the pull time, forward-looking.');
       tables=@( @{ subtitle=("14-day total booked: $grand"); columns=@('Date','HVAC-Service','Plumbing-Service','Total','Techs'); rows=$rows; footer='' } ) }
}

# ---------- M8: Booking rate by source (leads grouped by campaign, last 30 days) ----------
$script:SOURCE_RULES = @(
    @{ label='Angi';         cat='Lead Aggregators'; name='angi' },
    @{ label='Avoca';        cat='';                 name='avoca' },
    @{ label='Yelp';         cat='Yelp';             name='' },
    @{ label='LSA';          cat='Google LSA';       name='' },
    @{ label='Schedule Pro'; cat='';                 name='scheduler|scheduling pro' },
    @{ label='Costco';                  cat='Costco';                  name='' },
    @{ label='SEO';                     cat='SEO';                     name='' },
    @{ label='Main Line Number';        cat='Main Line Number';        name='' },
    @{ label='Google PPC';              cat='Google PPC';              name='' },
    @{ label='Texting';                 cat='Texting';                 name='' },
    @{ label='Outbound';                cat='Outbound';                name='' },
    @{ label='Google Business Profile'; cat='Google Business Profile'; name='' }
)
function Get-Metric-BookingBySource($Ctx, [datetime]$Date) {
    $camp = Get-CampaignMap $Ctx
    $today = Get-TodayPac $Ctx.Pac
    $since = $today.AddDays(-30).ToString('yyyy-MM-ddT00:00:00Z')
    $leads = Invoke-StPaged $Ctx "/crm/v2/tenant/$($Ctx.Tenant)/leads" @{ createdOnOrAfter=$since }
    $agg=[ordered]@{}
    foreach ($s in $script:SOURCE_RULES) { $agg[$s.label]=@{ leads=0; booked=0; conv=0 } }
    $agg['Other']=@{ leads=0; booked=0; conv=0 }
    foreach ($ld in $leads) {
        $cid="$($ld.campaignId)"; $cn=''; $ct=''
        if ($camp.ContainsKey($cid)) { $cn=$camp[$cid].name; $ct=$camp[$cid].cat }
        $label='Other'
        foreach ($s in $script:SOURCE_RULES) {
            $catOk  = ($s.cat  -eq '') -or ($ct -eq $s.cat)
            $nameOk = ($s.name -eq '') -or ($cn -match $s.name)
            if ($catOk -and $nameOk) { $label=$s.label; break }
        }
        $agg[$label].leads++
        if (-not (Is-EmptyVal $ld.bookingId)) { $agg[$label].booked++ }
        if ($ld.status -eq 'Converted') { $agg[$label].conv++ }
    }
    $rows=@()
    foreach ($k in $agg.Keys) {
        $a=$agg[$k]
        $rate = if ($a.leads -gt 0) { "{0:N0}%" -f (100.0*$a.booked/$a.leads) } else { '-' }
        $rows += ,@($k, $a.leads, $a.booked, $rate, $a.conv)
    }
    @{ id='booking-source'; title='Booking Rate by Source - last 30 days'; status='ok'; error=$null;
       notes=@(
         'Booked = lead has a booking (bookingId). Converted (last column) = lead became a job. Period: last 30 days.',
         'AVOCA CAVEAT: this row is leads ATTRIBUTED TO AVOCA CAMPAIGNS in ServiceTitan and their booked rate. It is NOT Avoca''s call-handling booking rate (answered vs booked) - that lives in Avoca and is not reachable here. Different metric; do not confuse.',
         'Source = marketing campaign category/name. Schedule Pro is largely self-serve online booking, so its rate reads high by nature. Other = leads not mapped to a named source.'
       );
       tables=@( @{ subtitle=''; columns=@('Source','Leads','Booked','Rate','Converted'); rows=$rows; footer='' } ) }
}

# ---------- M9: SILO / ROPP monthly (NOT in the daily snapshot; separate monthly endpoint) ----------
$script:SILO_ROPP_TAG = '962027'
$script:SILO_CALL_BUS = @('333','342817560')   # HVAC Service + HVAC Maintenance
$script:SILO_EST_TGL  = @(532267298,532269553,532279667,532275186,532275369,532272809,532279441)  # "Estimate ... TGL"
$script:SILO_ROSTER = @(
 @{disp='Noah Weng';last='weng';firsts=@('noah')},                   @{disp='Joe Mendoza';last='mendoza';firsts=@('joe','joseph')},
 @{disp='Benjamin Wyllie';last='wyllie';firsts=@('benjamin','ben')}, @{disp='Nikko April';last='april';firsts=@('nikko')},
 @{disp='Andrew Trujillo';last='trujillo';firsts=@('andrew')},       @{disp='Dustin Romine';last='romine';firsts=@('dustin')},
 @{disp='Juan Tlatenchi';last='tlatenchi';firsts=@('juan')},         @{disp='Brandon Moreno';last='moreno';firsts=@('brandon')},
 @{disp='Francisco Valencia';last='valencia';firsts=@('francisco')}, @{disp='Mario Castro';last='castro';firsts=@('mario')},
 @{disp='Cole Pantol';last='pantol';firsts=@('cole')},               @{disp='Nathan Colquitt';last='colquitt';firsts=@('nathan')},
 @{disp='Robert Silinzy';last='silinzy';firsts=@('robert','rob')},   @{disp='Alex Yakovchuk';last='yakovchuk';firsts=@('alex','oleksiy')}
)
function Match-SiloRoster($name) {
    if ([string]::IsNullOrWhiteSpace($name)) { return $null }
    $toks = [regex]::Matches($name.ToLower(),'[a-z]+') | ForEach-Object { $_.Value }
    foreach ($r in $script:SILO_ROSTER) { if (($toks -contains $r.last) -and (@($toks | Where-Object { $r.firsts -contains $_ }).Count -gt 0)) { return $r.disp } }
    $null
}
# id -> name INCLUDING inactive (required: generating-tech ids include former employees)
function Get-SiloIdNameMap($Ctx) {
    if ($Ctx.Cache.ContainsKey('siloIdName')) { return $Ctx.Cache['siloIdName'] }
    $m = @{}
    foreach ($q in @(@{}, @{active='false'})) {
        foreach ($e in (Invoke-StPaged $Ctx "/settings/v2/tenant/$($Ctx.Tenant)/technicians" $q)) { $m["$($e.id)"] = $e.name }
        foreach ($e in (Invoke-StPaged $Ctx "/settings/v2/tenant/$($Ctx.Tenant)/employees"   $q)) { if (-not $m.ContainsKey("$($e.id)")) { $m["$($e.id)"] = $e.name } }
    }
    $Ctx.Cache['siloIdName'] = $m; $m
}
function Get-Metric-SiloRopp($Ctx, [datetime]$MonthFirst) {
    $pac = $Ctx.Pac
    $sUtc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($MonthFirst,'Unspecified'),$pac)
    $eUtc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($MonthFirst.AddMonths(1),'Unspecified'),$pac)
    $sIso = $sUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ"); $eIso = $eUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
    $monthStr = $MonthFirst.ToString('yyyy-MM')
    $jt = Get-JobTypeMap $Ctx; $idName = Get-SiloIdNameMap $Ctx

    $callsPerTech=@{}; $tglPerTech=@{}; foreach ($r in $script:SILO_ROSTER) { $callsPerTech[$r.disp]=0; $tglPerTech[$r.disp]=0 }

    # CALLS: ROPP + svc/maint + Completed + new-opp, run by a roster tech (per-job assignments)
    $ropp = Invoke-StPaged $Ctx "/jpm/v2/tenant/$($Ctx.Tenant)/jobs" @{ tagTypeIds=$script:SILO_ROPP_TAG; jobStatus='Completed'; completedOnOrAfter=$sIso; completedBefore=$eIso }
    $callJobs = @($ropp | Where-Object { ("$($_.businessUnitId)" -in $script:SILO_CALL_BUS) -and (Test-NewOpportunity $_ $jt) })
    $siloJobs = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($j in $callJobs) {
        $as = Invoke-RestMethod -Method Get -Uri "$script:ApiBase/dispatch/v2/tenant/$($Ctx.Tenant)/appointment-assignments?jobId=$($j.id)&pageSize=50&page=1" -Headers $Ctx.Headers
        $seen=@{}
        foreach ($a in @($as.data)) {
            if (-not $a.active) { continue }
            $d = Match-SiloRoster $a.technicianName
            if ($d -and -not $seen.ContainsKey($d)) { $callsPerTech[$d]++; $seen[$d]=$true; [void]$siloJobs.Add("$($j.id)") }
        }
    }

    # TGLs: Estimate-TGL created in month, attributed via jobGeneratedLeadSource.employeeId
    foreach ($tid in $script:SILO_EST_TGL) {
        foreach ($j in (Invoke-StPaged $Ctx "/jpm/v2/tenant/$($Ctx.Tenant)/jobs" @{ jobTypeId=$tid; createdOnOrAfter=$sIso; createdBefore=$eIso })) {
            $g = $j.jobGeneratedLeadSource
            if (-not $g -or (Is-EmptyVal $g.employeeId)) { continue }
            $nm = if ($idName.ContainsKey("$($g.employeeId)")) { $idName["$($g.employeeId)"] } else { $null }
            $d = Match-SiloRoster $nm
            if ($d) { $tglPerTech[$d]++ }
        }
    }

    $rows=@(); $totC=0; $totT=0
    foreach ($r in $script:SILO_ROSTER) {
        $c=$callsPerTech[$r.disp]; $t=$tglPerTech[$r.disp]; $totC+=$c; $totT+=$t
        $conv = if ($c -gt 0) { "{0:N1}%" -f (100.0*$t/$c) } else { '-' }
        $rows += ,@($r.disp, $c, $t, $conv)
    }
    $siloConv = if ($totC -gt 0) { "{0:N1}%" -f (100.0*$totT/$totC) } else { '-' }
    @{ id='silo-ropp'; title=("SILO / ROPP - $monthStr"); status='ok'; error=$null; month=$monthStr;
       notes=@('Calibrated to be correct against LIVE ServiceTitan - NOT calibrated to match the example dashboard''s numbers.',
               'Call = ROPP-tagged, HVAC Service/Maintenance, completed that month, new-opportunity, run by a roster tech. TGL = an Estimate-TGL job created that month, credited to the roster tech who generated the lead. Conversion = TGLs / calls.');
       tables=@( @{ subtitle=''; columns=@('Technician','Calls','TGLs','Conversion'); rows=$rows; footer=("SILO TOTAL   Calls $totC   TGLs $totT   Conversion $siloConv") } ) }
}
function Build-SiloSnapshot {
    param($Ctx, [datetime]$MonthFirst, [datetime]$CurMonthFirst)
    $pulled = (Get-UtcNow)
    try { $b = Get-Metric-SiloRopp $Ctx $MonthFirst; $b.pulledAt = $pulled }
    catch { $b = New-ErrorBlock 'silo-ropp' 'SILO / ROPP' ("$($_.Exception.Message)") }
    # final = a completed past month: its ServiceTitan data is done, computed once, never changes.
    @{ month=$MonthFirst.ToString('yyyy-MM'); final=($MonthFirst -lt $CurMonthFirst); generatedAt=(Get-UtcNow); block=$b }
}

# ============================================================================
#  M-Revenue: Plumbing revenue (pre-tax subTotal, billed not collected), Today / MTD / YTD
#  DEFINITION (verbatim from the Plumbing manager, verified 2026-08-03 against their revenue.json:
#  Install BU 408662213 on 2026-08-03 = $15,847.05, exact match):
#    * Revenue = sum of each invoice's `subTotal` (PRE-TAX), grouped by the invoice's date.
#      Billed / invoiced, NOT collected. Tax excluded. Discounts / refunds / credits are NOT
#      stripped - they appear naturally as negative-dollar invoices; subTotal is summed as-is
#      (a value can be negative).
#    * Source = ServiceTitan Accounting API v2 invoices endpoint (NOT the reporting API), filtered
#      by invoicedOnOrAfter / invoicedOnBefore. That endpoint SILENTLY IGNORES a businessUnitIds
#      query param on this tenant, so the Plumbing BU set is filtered in code (Get-Invoices).
#    * Time boundaries = plain UTC calendar days (invoiceDate is a UTC-midnight date). We do NOT
#      use Get-PacDayWindow here (it would shift +7/8h and bucket the wrong day).
#    * Money is summed as [decimal], never [double], so totals match to the cent.
#  CACHING / FRESHNESS (matches the manager's "recompute this month + last month, freeze older"):
#    Per-month cache files data/revenue-<YYYY-MM>.json store per-BU per-day subTotal sums for the 4
#    Plumbing BUs, plus a `final` flag + generatedAt. The current month and the previous month
#    (relative to today's calendar month) are ALWAYS recomputed on every run (final=false), so
#    backdated corrections flow into them. Any month older than the previous month is frozen: if a
#    final cache exists it is reused; otherwise it is computed once and written final=true. The very
#    first run therefore backfills + freezes Jan .. prev-month for the selected date's year.
#  AS-OF: computed as of the snapshot's selected date D. Today = D's single day; MTD = 1st of D's
#  month .. D inclusive; YTD = Jan 1 of D's year .. D inclusive. Days after D (later postings in a
#  past month's cache) are excluded by comparing the stored day key to D.
# ============================================================================
$script:REV_PLMB_BUS = [ordered]@{ '353'='Service'; '354'='Maintenance'; '595105985'='Drains'; '408662213'='Install' }

function Get-RevenueDataDir {
    $d = Join-Path (Split-Path $script:LibRoot -Parent) 'data'
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
    $d
}
function Format-Money([decimal]$v) {
    $s = ([Math]::Abs($v)).ToString('#,##0.00', [Globalization.CultureInfo]::InvariantCulture)
    if ($v -lt 0) { "-`$$s" } else { "`$$s" }
}
# Compute per-BU per-day subTotal sums (decimal, cent-rounded) for one calendar month, Plumbing BUs only.
function Compute-RevenueMonth($Ctx, [datetime]$MonthFirst) {
    $startIso = Get-UtcDayIso $MonthFirst
    $endIso   = Get-UtcDayIso ($MonthFirst.AddMonths(1))
    $inv = Get-Invoices $Ctx $startIso $endIso
    $days = [ordered]@{}
    foreach ($bu in $script:REV_PLMB_BUS.Keys) { $days[$bu] = @{} }
    foreach ($i in $inv) {
        $bu = $i.buId
        if (-not $script:REV_PLMB_BUS.Contains($bu)) { continue }   # filter Plumbing BUs in CODE (server ignores the filter)
        $dayKey = (Parse-Utc $i.invoiceDate).ToString('yyyy-MM-dd') # plain-UTC calendar date
        if (-not $days[$bu].ContainsKey($dayKey)) { $days[$bu][$dayKey] = [decimal]0 }
        $days[$bu][$dayKey] += $i.subTotal
    }
    foreach ($bu in $script:REV_PLMB_BUS.Keys) {
        foreach ($k in @($days[$bu].Keys)) { $days[$bu][$k] = [decimal][Math]::Round($days[$bu][$k], 2) }
    }
    $days
}
# Ensure the month cache for $MonthFirst exists per the freshness rule, and return the parsed cache.
function Ensure-RevenueMonth($Ctx, [datetime]$MonthFirst, [datetime]$CurFirst) {
    $dataDir  = Get-RevenueDataDir
    $monthStr = $MonthFirst.ToString('yyyy-MM')
    $file     = Join-Path $dataDir "revenue-$monthStr.json"
    $prevFirst = $CurFirst.AddMonths(-1)
    $recompute = ($MonthFirst -ge $prevFirst)   # current or previous month -> always recompute
    if (-not $recompute -and (Test-Path $file)) {
        $c = $null; try { $c = Get-Content $file -Raw | ConvertFrom-Json } catch { $c = $null }
        if ($c -and $c.final -eq $true) { return $c }   # frozen month with a final cache: reuse
    }
    $days    = Compute-RevenueMonth $Ctx $MonthFirst
    $isFinal = (-not $recompute)                 # frozen months written final=true; cur/prev final=false
    $cache   = [ordered]@{ month=$monthStr; final=$isFinal; generatedAt=(Get-UtcNow); days=$days }
    ($cache | ConvertTo-Json -Depth 8) | Set-Content -Path $file -Encoding UTF8
    Get-Content $file -Raw | ConvertFrom-Json   # re-read for a consistent PSCustomObject shape
}

function Get-Metric-Revenue($Ctx, [datetime]$Date) {
    $today    = Get-TodayPac $Ctx.Pac
    $curFirst = Get-UtcMonthStart $today            # today's calendar month (Pacific is irrelevant to the rule)
    $dMonth   = Get-UtcMonthStart $Date
    $yearStart= Get-UtcYearStart $Date

    # Ensure a cache for every month Jan(D.year) .. month(D) (YTD needs them all).
    $monthCaches = [ordered]@{}
    $m = $yearStart
    while ($m -le $dMonth) {
        $monthCaches[$m.ToString('yyyy-MM')] = (Ensure-RevenueMonth $Ctx $m $curFirst)
        $m = $m.AddMonths(1)
    }

    $dKey          = $Date.ToString('yyyy-MM-dd')
    $monthStartKey = $dMonth.ToString('yyyy-MM-dd')
    $yearStartKey  = $yearStart.ToString('yyyy-MM-dd')

    $tot = @{}   # period -> bu -> [decimal]
    foreach ($p in 'today','mtd','ytd') { $tot[$p]=@{}; foreach ($bu in $script:REV_PLMB_BUS.Keys) { $tot[$p][$bu]=[decimal]0 } }
    foreach ($mk in $monthCaches.Keys) {
        $cache = $monthCaches[$mk]
        if ($null -eq $cache.days) { continue }
        foreach ($bu in $script:REV_PLMB_BUS.Keys) {
            $buProp = $cache.days.PSObject.Properties[$bu]
            if (-not $buProp) { continue }
            foreach ($dp in $buProp.Value.PSObject.Properties) {
                $dayKey = $dp.Name
                if ($dayKey -gt $dKey) { continue }         # a later posting in a past month - not yet as of D
                if ($dayKey -lt $yearStartKey) { continue } # safety (should not occur)
                $val = [decimal]$dp.Value
                $tot['ytd'][$bu] += $val
                if ($dayKey -ge $monthStartKey) { $tot['mtd'][$bu] += $val }
                if ($dayKey -eq $dKey)          { $tot['today'][$bu] += $val }
            }
        }
    }

    $plmb = @{}; foreach ($p in 'today','mtd','ytd') { $s=[decimal]0; foreach ($bu in $script:REV_PLMB_BUS.Keys){ $s += $tot[$p][$bu] }; $plmb[$p]=$s }

    $todayLbl = "Today ($($Date.ToString('MMM d')))"
    $mtdLbl   = "Month to date ($($dMonth.ToString('MMM 1')) - $($Date.ToString('MMM d')))"
    $ytdLbl   = "Year to date ($($yearStart.ToString('MMM 1')) - $($Date.ToString('MMM d')))"

    $summaryRows = @(
        ,@($todayLbl, (Format-Money $plmb['today']))
        ,@($mtdLbl,   (Format-Money $plmb['mtd']))
        ,@($ytdLbl,   (Format-Money $plmb['ytd']))
    )
    $buRows = @()
    foreach ($bu in $script:REV_PLMB_BUS.Keys) {
        $buRows += ,@($script:REV_PLMB_BUS[$bu], (Format-Money $tot['today'][$bu]), (Format-Money $tot['mtd'][$bu]), (Format-Money $tot['ytd'][$bu]))
    }
    $buFoot = "PLUMBING TOTAL   Today {0}    MTD {1}    YTD {2}" -f (Format-Money $plmb['today']), (Format-Money $plmb['mtd']), (Format-Money $plmb['ytd'])

    $notes = @(
        'Revenue = each invoice''s pre-tax subTotal, summed by the invoice date. BILLED / invoiced, NOT collected. Tax excluded.',
        'Discounts, refunds and credits are included as-is - they appear naturally as negative-dollar invoices; nothing is stripped out.',
        'Plumbing = Service + Maintenance + Drains + Install. Day boundaries are plain UTC calendar dates (the invoice date), not Pacific.',
        'This month and last month are fully recomputed on every refresh (so backdated corrections update them); any older month is frozen after its first computation.',
        'CAVEAT - NOT FINAL: Today, this month''s MTD, and YTD are PARTIAL. Invoices keep posting, so these figures will keep rising through the day and month.'
    )

    @{ id='revenue'; title='Revenue - Plumbing (billed, pre-tax)'; status='ok'; error=$null;
       notes=$notes;
       tables=@(
         @{ subtitle='Plumbing revenue'; columns=@('Period','Revenue'); rows=$summaryRows; footer='' },
         @{ subtitle='By business unit'; columns=@('Business Unit','Today','MTD','YTD'); rows=$buRows; footer=$buFoot }
       ) }
}

# ============================================================================
#  M-SiloRevenue: SILO revenue + flip rate (on the same Revenue tab as Plumbing)
#  DEFINITION (verified via live investigation of saved report 648754648, category 'technician'):
#    * SILO revenue = the SOLD/SIGNED pre-tax estimate subtotal on TURNOVER (TGL) jobs, credited
#      to the TURNOVER-CALL DAY. A row is a turnover job when JobType CONTAINS "TGL" (observed:
#      "Estimate AC TGL", "Estimate Mini Split TGL"). EstimateSalesSubtotal is already SOLD-ONLY
#      (0 when nothing was sold on the job), pre-tax. Summed as [decimal].
#    * Turnover-call day = the TGL job's CREATION day (DateType=2 = Job Creation Date). Verified:
#      the estimate-TGL job and its source turnover call are created the same Pacific day.
#    * Flip rate = (TGL jobs with a sold estimate) / (total TGL jobs created), per period.
#      Shown as '-' when the period has zero TGL jobs.
#  SOURCE: ServiceTitan Reporting API, saved report 648754648, category 'technician'. Run via
#    Invoke-StReport (POST + hasMore paging + 429 retry). From/To are PLAIN Pacific calendar dates
#    "yyyy-MM-dd" - the report windows internally; they are NOT UTC-converted.
#  EFFICIENCY: ONE pull per snapshot - From = Jan 1 of D's year (Pacific), To = D (Pacific),
#    DateType=2 (a full year is ~one page, hasMore handles the rare overflow). TGL rows are then
#    bucketed by CreatedDate's Pacific calendar day to compute Today / MTD / YTD in a single pass.
#    VERIFIED 2026-08-03: bucketing the YTD pull to 2026-08-03 yields the identical TGL job SET and
#    revenue as a direct From=To=2026-08-03 pull.
#  NOT FROZEN / RETROACTIVE BY DESIGN: an estimate sold later retroactively adds to its earlier
#    turnover day, so past days can still rise. The whole year is recomputed every refresh; this
#    block is NEVER cached/frozen (unlike Plumbing revenue). That is correct, not a bug.
#  FAIL LOUD: if the report POST errors, or JobType / EstimateSalesSubtotal / CreatedDate are
#    absent, the metric errors - it never fabricates a number.
# ============================================================================
$script:SILO_REV_REPORT_ID  = '648754648'
$script:SILO_REV_REPORT_CAT = 'technician'

# The report's CreatedDate is a Pacific-local ISO string carrying its own offset (e.g.
# '2026-08-03T00:00:00-07:00'). Parse as DateTimeOffset and convert to the Pacific zone before
# taking the calendar date, so day-bucketing is correct regardless of the host machine's timezone.
# FAIL-LOUD GUARD: [DateTimeOffset]::Parse on a string with NO explicit offset (e.g.
# "2026-08-03T00:00:00") silently assumes the HOST machine's local offset - on a UTC deploy
# runner that would shift every row 7-8h into the wrong Pacific day with no error at all. The
# live report has always returned an explicit offset (trailing 'Z' or '+HH:MM'/'-HH:MM'); require
# that here so a future report change that drops the offset fails loud instead of silently
# mis-bucketing revenue.
function Get-SiloReportPacDay($Ctx, [string]$s) {
    if ($s -notmatch '(Z|[+\-]\d{2}:?\d{2})$') {
        throw "Get-SiloReportPacDay: CreatedDate '$s' has no explicit UTC offset (Z or +/-HH:MM) - refusing to guess the host timezone."
    }
    $dto = [DateTimeOffset]::Parse($s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    ([TimeZoneInfo]::ConvertTime($dto, $Ctx.Pac)).Date
}

function Get-Metric-SiloRevenue($Ctx, [datetime]$Date) {
    # $Date is the Pacific-selected snapshot date (the day the dashboard is being viewed "as of").
    # Get-UtcMonthStart/Get-UtcYearStart are reused here only for their .Year/.Month arithmetic
    # (finding the 1st of the month / Jan 1) - that's timezone-agnostic despite the "Utc" name.
    # This is NOT a UTC day-boundary computation; all day bucketing below is done in Pacific via
    # Get-SiloReportPacDay.
    $monthStart = Get-UtcMonthStart $Date            # 1st of D's calendar month
    $yearStart  = Get-UtcYearStart $Date             # Jan 1 of D's year
    $fromStr = $yearStart.ToString('yyyy-MM-dd')     # PLAIN Pacific calendar dates - not UTC-converted
    $toStr   = $Date.ToString('yyyy-MM-dd')

    $body = @{ parameters = @(
        @{ name='DateType'; value=2 },               # 2 = Job Creation Date = the turnover-call day
        @{ name='From'; value=$fromStr },
        @{ name='To';   value=$toStr }
    ) }
    $rep = Invoke-StReport $Ctx $script:SILO_REV_REPORT_CAT $script:SILO_REV_REPORT_ID $body
    $col = Get-ReportColMap $rep.fields @('JobType','EstimateSalesSubtotal','CreatedDate')
    $iType = $col['JobType']; $iSub = $col['EstimateSalesSubtotal']; $iCr = $col['CreatedDate']

    $dDay = $Date.Date; $mDay = $monthStart.Date
    $per = @{}; foreach ($p in 'today','mtd','ytd') { $per[$p] = @{ rev=[decimal]0; total=0; sold=0 } }

    foreach ($row in $rep.rows) {
        # JobType substring match ("TGL") is the VERIFIED source of truth for this metric - it
        # reproduces the manager's real target (18 jobs on 2026-08-03, 2,220 YTD vs the ~2,229
        # target), independently reproduced to the cent (2026-08-03 Today $72,713.62; 2026-07-29
        # $213,964.02 / 9 of 21). The report exposes no JobTypeId column, so there is no way to
        # filter against the canonical $script:SILO_EST_TGL id list here. Do NOT "optimize" this
        # to an id-based filter without re-verifying against those exact target numbers first.
        if ("$($row[$iType])" -notmatch 'TGL') { continue }        # turnover jobs only
        $sub = [decimal]$row[$iSub]                                # sold-only, pre-tax; 0 if nothing sold
        $pac = Get-SiloReportPacDay $Ctx "$($row[$iCr])"           # turnover day (Pacific)
        if ($pac -gt $dDay) { continue }                           # guard: creation after D (shouldn't occur, To=D)
        $per['ytd'].rev += $sub; $per['ytd'].total++; if ($sub -gt 0) { $per['ytd'].sold++ }
        if ($pac -ge $mDay) { $per['mtd'].rev += $sub; $per['mtd'].total++; if ($sub -gt 0) { $per['mtd'].sold++ } }
        if ($pac -eq $dDay) { $per['today'].rev += $sub; $per['today'].total++; if ($sub -gt 0) { $per['today'].sold++ } }
    }

    $lbls = @{
        today = "Today ($($Date.ToString('MMM d')))"
        mtd   = "Month to date ($($monthStart.ToString('MMM 1')) - $($Date.ToString('MMM d')))"
        ytd   = "Year to date ($($yearStart.ToString('MMM 1')) - $($Date.ToString('MMM d')))"
    }
    $revRows=@(); $flipRows=@()
    foreach ($p in 'today','mtd','ytd') {
        $x = $per[$p]
        $revRows  += ,@($lbls[$p], (Format-Money $x.rev))
        $flip = if ($x.total -gt 0) { "{0:N1}%" -f (100.0*$x.sold/$x.total) } else { '-' }
        $flipRows += ,@($lbls[$p], $flip, "$($x.sold) of $($x.total)")
    }

    $notes = @(
        'SILO revenue = the SOLD / signed estimate subtotal (PRE-TAX) on turnover (TGL) jobs, credited to the TURNOVER-CALL DAY (the day the TGL job was created). Sold-only: a turnover with nothing sold contributes $0.',
        'Flip rate = turnover jobs that sold an estimate / total turnover jobs created, per period. The count behind each % is shown as "N of M turnovers sold".',
        'Turnover (TGL) jobs only. Day boundaries are Pacific (the report''s Created Date carries its own Pacific offset).',
        'NOT FINAL / RETROACTIVE BY DESIGN: an estimate sold later adds to its earlier turnover day, so Today, MTD and YTD can still rise. The full year is recomputed every refresh; this block is never frozen.'
    )

    @{ id='silo-revenue'; title='Revenue - SILO (sold/signed, pre-tax)'; status='ok'; error=$null;
       notes=$notes;
       tables=@(
         @{ subtitle='SILO revenue'; columns=@('Period','Revenue'); rows=$revRows; footer='' },
         @{ subtitle='Flip rate'; columns=@('Period','Flip Rate','Turnovers sold'); rows=$flipRows; footer='' }
       ) }
}

# ---------- registry + snapshot assembler ----------
$script:METRIC_DEFS = @(
    @{ id='call-counts';    title='Call Count';               act={ param($c,$d) Get-Metric-CallCounts   $c $d } },
    @{ id='cancellations';  title='Cancellations';            act={ param($c,$d) Get-Metric-Cancellations $c $d } },
    @{ id='calls-per-tech'; title='Calls per Tech';           act={ param($c,$d) Get-Metric-CallsPerTech  $c $d } },
    @{ id='overtime';       title='Overtime';                 act={ param($c,$d) Get-Metric-Overtime      $c $d } },
    @{ id='dispatch-arrival'; title='Dispatch & Arrival';     act={ param($c,$d) Get-Metric-DispatchArrival $c $d } },
    @{ id='maint-14d';      title='Maintenances (14d)';       act={ param($c,$d) Get-Metric-Maint14       $c $d } },
    @{ id='club-members';   title='Club Members Left to Run'; act={ param($c,$d) Get-Metric-ClubMembers   $c $d } },
    @{ id='call-board';     title='3-Day Call Board';         act={ param($c,$d) Get-Metric-CallBoard     $c $d } },
    @{ id='booking-source'; title='Booking Rate by Source';   act={ param($c,$d) Get-Metric-BookingBySource $c $d } },
    @{ id='revenue';        title='Revenue - Plumbing';       act={ param($c,$d) Get-Metric-Revenue       $c $d } },
    @{ id='silo-revenue';   title='Revenue - SILO';           act={ param($c,$d) Get-Metric-SiloRevenue   $c $d } }
)

function New-ErrorBlock($id,$title,$msg) { @{ id=$id; title=$title; status='error'; error=$msg; notes=@(); tables=@(); pulledAt=(Get-UtcNow) } }

function Build-Snapshot {
    param($Ctx, [datetime]$Date, [datetime]$Today)
    $metrics=@()
    foreach ($def in $script:METRIC_DEFS) {
        $pulled = (Get-UtcNow)
        try {
            $b = & $def.act $Ctx $Date
            $b.pulledAt = $pulled
            $metrics += $b
        } catch {
            $metrics += (New-ErrorBlock $def.id $def.title ("$($_.Exception.Message)"))
        }
    }
    # final = a completed past Pacific day: its ServiceTitan data is done, so this snapshot will not change
    # (barring backdated edits). Today is never final; a future date is not final either.
    @{ date=$Date.ToString('yyyy-MM-dd'); isToday=($Date.Date -eq $Today.Date); final=($Date.Date -lt $Today.Date); generatedAt=(Get-UtcNow); metrics=$metrics }
}
