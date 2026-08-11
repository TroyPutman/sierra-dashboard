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

# ---------- M7: Call board - calls SCHEDULED on the board per day, next 14 days (calendar view) ----------
# DEFINITION REWRITTEN 2026-08-06 (business owner: the board must show what is SCHEDULED that day,
# not what has been finished). Per Pacific day in the 14-day window, count DISTINCT JOBS that have at
# least one appointment SCHEDULED that day, split into three MUTUALLY-EXCLUSIVE categories:
#   * ROPPS   = the job carries the ROPP tag (tagTypeId 962027) - counted here regardless of trade.
#   * HVAC    = an HVAC business-unit job that is NOT ROPP-tagged.
#   * Plumbing= a Plumbing business-unit job that is NOT ROPP-tagged.
# COMPLETION-INDEPENDENT: there is deliberately NO jobStatus='Completed' filter and NO new-opportunity
# filter. Completing a call does NOT change the count - a call that ran this morning is still a call
# that was on the board today. The ONLY thing that removes a call is a CANCELLATION:
#   * an appointment whose status is 'Canceled' does not put the job on that day's board, AND
#   * a job whose jobStatus is 'Canceled' is off the board entirely.
# This is why the OLD version read tiny (it counted only HVAC-Service + Plumbing-Service NEW-OPPORTUNITY
# jobs - dropping HVAC/Plumbing install, maintenance, sales, drains, every recall/warranty, and the
# whole ROPP book). MUTUALLY EXCLUSIVE (ROPP carved OUT of HVAC/Plumbing) is calibrated to LIVE data:
# on Fri 2026-08-07 the HVAC-BU non-ROPP job count is 81 and the ROPP-included count is 108 - the board
# shows the smaller, carved-out figure.
function Get-Metric-CallBoard($Ctx, [datetime]$Date) {
    $techBU = Get-TechBUMap $Ctx
    $ROPP_TAG = 962027                                   # ServiceTitan job tag "ROPP"
    $tradeBUs = @($script:HVAC_BUS + $script:PLMB_BUS)   # every HVAC + Plumbing business unit

    # Non-opportunity job types: configurable (config.json -> callBoard.nonOpportunityJobTypeIds),
    # never hard-coded. A call whose jobTypeId is in this set is shown but NOT counted as an
    # opportunity. FAIL LOUD: if any configured id is not a real job type, surface an on-screen
    # error rather than silently miscounting.
    $cfg = Get-DashConfig
    $nonOppIds = @()
    if ($cfg -and $cfg.PSObject.Properties['callBoard'] -and $cfg.callBoard.PSObject.Properties['nonOpportunityJobTypeIds']) {
        $nonOppIds = @($cfg.callBoard.nonOpportunityJobTypeIds | ForEach-Object { "$_" })
    }
    if ($nonOppIds.Count -gt 0) {
        $validJt = @{}
        foreach ($jt in (Invoke-StPaged $Ctx "/jpm/v2/tenant/$($Ctx.Tenant)/job-types" @{ active='Any' })) { $validJt["$($jt.id)"] = $true }
        $badIds = @($nonOppIds | Where-Object { -not $validJt.ContainsKey($_) })
        if ($badIds.Count -gt 0) {
            return @{ id='call-board'; title='Call Board - calls scheduled, next 14 days'; status='error';
                error=("config error: callBoard.nonOpportunityJobTypeIds contains job type id(s) not found in the ServiceTitan job-type catalog: " + ($badIds -join ', ') + ". Fix config.json."); tables=@() }
        }
    }
    $nonOppSet = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($x in $nonOppIds) { [void]$nonOppSet.Add($x) }

    $today = Get-TodayPac $Ctx.Pac; $endDay = $today.AddDays(14)
    $sUtc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($today,'Unspecified'),$Ctx.Pac)
    $eUtc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($endDay,'Unspecified'),$Ctx.Pac)
    $sIso = $sUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ"); $eIso = $eUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
    $days = 0..13 | ForEach-Object { $today.AddDays($_) }
    $dayKeys = @(); foreach ($dd in $days) { $dayKeys += $dd.ToString('yyyy-MM-dd') }

    # every appointment starting in the window (ANY status; we exclude Canceled explicitly so a real
    # cancellation removes the call - completion is NOT a factor). One job can appear on several days;
    # it is deduped WITHIN each day so a job with two visits the same day counts once that day.
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
    # Per Pacific day, split each mutually-exclusive bucket (HVAC / ROPPS / Plumbing) into
    # opportunities vs non-opportunities, and additionally break the HVAC bucket out per business unit.
    $hvOpp=@{}; $hvNon=@{}; $rpOpp=@{}; $rpNon=@{}; $plOpp=@{}; $plNon=@{}; $buOpp=@{}; $buNon=@{}
    foreach ($k in $dayKeys) {
        $hvOpp[$k]=0; $hvNon[$k]=0; $rpOpp[$k]=0; $rpNon[$k]=0; $plOpp[$k]=0; $plNon[$k]=0
        $buOpp[$k]=@{}; $buNon[$k]=@{}
        foreach ($bu in $script:HVAC_BUS) { $buOpp[$k]["$bu"]=0; $buNon[$k]["$bu"]=0 }
    }
    if ($byJob.Count -gt 0) {
        $jm = Get-JobsByIds $Ctx ($byJob.Keys)
        foreach ($jid in $byJob.Keys) {
            $job=$jm[$jid]; $bu="$($job.businessUnitId)"
            if ($job.jobStatus -eq 'Canceled') { continue }          # cancelled job = off the board (completion is NOT excluded)
            if ($tradeBUs -notcontains $bu) { continue }             # non-trade unit (e.g. Inventory)
            $isRopp = (@($job.tagTypeIds) -contains $ROPP_TAG)
            $isNon  = $nonOppSet.Contains("$($job.jobTypeId)")       # non-opportunity job type (config-driven)
            $seen=@{}
            foreach ($pd in $byJob[$jid]) {
                if (-not $hvOpp.ContainsKey($pd) -or $seen.ContainsKey($pd)) { continue }
                $seen[$pd]=$true
                if     ($isRopp)                        { if ($isNon) { $rpNon[$pd]++ } else { $rpOpp[$pd]++ } }   # ROPPS (mutually exclusive)
                elseif ($script:HVAC_BUS -contains $bu) { if ($isNon) { $hvNon[$pd]++; $buNon[$pd]["$bu"]++ } else { $hvOpp[$pd]++; $buOpp[$pd]["$bu"]++ } }
                elseif ($script:PLMB_BUS -contains $bu) { if ($isNon) { $plNon[$pd]++ } else { $plOpp[$pd]++ } }
            }
        }
    }

    # technicians scheduled per day (HVAC + Plumbing units) - secondary context
    $shifts = Invoke-StPaged $Ctx "/dispatch/v2/tenant/$($Ctx.Tenant)/technician-shifts" @{ startsOnOrAfter=$sIso }   # startsBefore ignored by API; client-filter
    $techByDay=@{}; foreach ($k in $dayKeys) { $techByDay[$k]=New-Object 'System.Collections.Generic.HashSet[string]' }
    foreach ($sh in $shifts) {
        if (-not $sh.active) { continue }
        $t = Parse-Utc $sh.start; if (-not ($t -ge $sUtc -and $t -lt $eUtc)) { continue }
        $pd=([TimeZoneInfo]::ConvertTimeFromUtc($t,$Ctx.Pac)).ToString('yyyy-MM-dd')
        $tid="$($sh.technicianId)"; $bu=$techBU[$tid]
        if ($null -eq $bu -or $tradeBUs -notcontains $bu) { continue }
        if ($techByDay.ContainsKey($pd)) { [void]$techByDay[$pd].Add($tid) }
    }

    # Calendar table: per day, opportunities + non-opportunities for each bucket, plus techs.
    # Headline board number = opportunities; non-opportunities are carried alongside, not summed in.
    $rows=@(); $oppGrand=0; $nonGrand=0
    foreach ($dd in $days) {
        $k=$dd.ToString('yyyy-MM-dd')
        $rows += ,@($k, [int]$hvOpp[$k], [int]$hvNon[$k], [int]$rpOpp[$k], [int]$rpNon[$k], [int]$plOpp[$k], [int]$plNon[$k], [int]$techByDay[$k].Count)
        $oppGrand += $hvOpp[$k]+$rpOpp[$k]+$plOpp[$k]; $nonGrand += $hvNon[$k]+$rpNon[$k]+$plNon[$k]
    }
    # Per-line breakdown, one row per (day, line): the 5 HVAC business units, then ROPPS, then Plumbing.
    # Each line carries opportunity / non-opportunity / total; the 5 HVAC lines sum to the HVAC bucket.
    $lineRows=@()
    foreach ($dd in $days) {
        $k=$dd.ToString('yyyy-MM-dd')
        foreach ($bu in $script:HVAC_BUS) {
            $b="$bu"; $o=[int]$buOpp[$k][$b]; $n=[int]$buNon[$k][$b]
            $lineRows += ,@($k, "HVAC:$b", "$($script:BU_NAMES[$b])", $o, $n, ($o+$n))
        }
        $lineRows += ,@($k, 'ROPPS', 'SILO / ROPPS', [int]$rpOpp[$k], [int]$rpNon[$k], [int]($rpOpp[$k]+$rpNon[$k]))
        $lineRows += ,@($k, 'PLMB',  'Plumbing',     [int]$plOpp[$k], [int]$plNon[$k], [int]($plOpp[$k]+$plNon[$k]))
    }
    @{ id='call-board'; title='Call Board - calls scheduled, next 14 days'; status='ok'; error=$null;
       notes=@('Count = calls SCHEDULED on the board that day (distinct jobs with a visit that day), minus cancellations. Completing a call does NOT change the count - only a cancellation removes one. HVAC / SILO-ROPPS / Plumbing are mutually exclusive: ROPPS = the ROPP-tagged book (any trade); HVAC / Plumbing = their business-unit calls that are NOT ROPP-tagged.',
               'Opportunities vs non-opportunities: a call is a NON-opportunity when its job type is one of the configured non-opportunity job types (edit the list in config.json -> callBoard.nonOpportunityJobTypeIds). Non-opportunities are shown but are NOT included in the headline opportunity count.',
               'HVAC is broken out by business unit: HVAC - Service (333), HVAC - Install - AOR (337), HVAC - Maintenance (342817560), HVAC - Sales NR (370), HVAC - Sales Costco NR (340802904).',
               'Techs = HVAC + Plumbing technicians scheduled that day (secondary context). As of the pull time, forward-looking; light/weekend days are expected to be thin.');
       tables=@(
         @{ subtitle=("14-day total: $oppGrand opportunities + $nonGrand non-opportunities"); columns=@('Date','HVAC_opp','HVAC_non','ROPPS_opp','ROPPS_non','PLMB_opp','PLMB_non','Techs'); rows=$rows; footer='' },
         @{ subtitle='Per-business-unit breakdown (opportunities vs non-opportunities)'; columns=@('Date','Line','Label','Opp','Non','Total'); rows=$lineRows; footer='' }
       ) }
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
#  M-SiloRevenue: SILO revenue (on the same Revenue tab as Plumbing)
#  FLIP RATE HAS MOVED OUT OF THIS BLOCK (2026-08-10). This metric used to also publish a "Flip
#    rate" table computed as (TGL jobs with a sold estimate) / (total TGL jobs created) off this
#    same report, which read 38.5% YTD. That is NOT the SILO manager's definition: theirs is
#    (TGLs created) / (ROPP calls ran) off two entirely different reports, and read 48.4% YTD -
#    a ~10-point gap on the same-named number. The business owner's decision was to match the
#    manager, so the flip rate now lives in its own metric (`silo-flip`, Build-SiloFlipSnapshot
#    below) and the old table was REMOVED rather than kept alongside - two different numbers both
#    labelled "SILO flip rate" on one dashboard is worse than either number alone. The sold/total
#    counts are still accumulated by Get-SiloReportPeriod (cheap, and they are the natural output
#    of the same row loop) - they are simply no longer rendered here.
#  DEFINITION (verified via live investigation of saved report 648754648, category 'technician'):
#    * SILO revenue = the SOLD/SIGNED pre-tax estimate subtotal on TURNOVER (TGL) jobs, credited
#      to the TURNOVER-CALL DAY. A row is a turnover job when JobType CONTAINS "TGL" (observed:
#      "Estimate AC TGL", "Estimate Mini Split TGL"). EstimateSalesSubtotal is already SOLD-ONLY
#      (0 when nothing was sold on the job), pre-tax. Summed as [decimal].
#    * Turnover-call day = the TGL job's CREATION day (DateType=2 = Job Creation Date). Verified:
#      the estimate-TGL job and its source turnover call are created the same Pacific day.
#  SOURCE: ServiceTitan Reporting API, saved report 648754648, category 'technician'. Run via
#    Invoke-StReport (POST + hasMore paging + 429 retry). From/To are PLAIN Pacific calendar dates
#    "yyyy-MM-dd" - the report windows internally; they are NOT UTC-converted.
#  PLATFORM-INDEPENDENT (rewritten 2026-08-06): THREE report pulls per snapshot, one per period,
#    each using the report's OWN server-side From/To Pacific-day filter (DateType=2). There is NO
#    client-side date parsing of report rows at all - the report buckets by the tenant's (Pacific)
#    calendar day internally, so the result is provably identical on Windows PS5.1 and the Linux/UTC
#    pwsh7 CI runner. This replaces the prior single-pull approach that bucketed each row's
#    CreatedDate into a Pacific day client-side - fragile because ConvertFrom-Json yields CreatedDate
#    as a different .NET type per host (offset-bearing [string] on PS5.1 vs UTC-normalized [datetime]
#    on pwsh7), which tripped the fail-loud guard and broke SILO live.
#      * Today: From = To = D.   * MTD: From = 1st of D's month, To = D.   * YTD: From = Jan 1, To = D.
#    From/To are built straight from D's calendar components (year/month/day) - never converted.
#    TRADEOFF: 3 rapid POSTs will hit the tenant's report-run 429 limit; Invoke-StReport backs off on
#    Retry-After. Acceptable - SILO recomputes on the schedule, not interactively.
#  NOT FROZEN / RETROACTIVE BY DESIGN: an estimate sold later retroactively adds to its earlier
#    turnover day, so past days can still rise. The whole year is recomputed every refresh; this
#    block is NEVER cached/frozen (unlike Plumbing revenue). That is correct, not a bug.
#  FAIL LOUD: if any report POST errors, or the JobType / EstimateSalesSubtotal columns are absent,
#    the metric errors - it never fabricates a number.
# ============================================================================
$script:SILO_REV_REPORT_ID  = '648754648'
$script:SILO_REV_REPORT_CAT = 'technician'

# Run the SILO report for ONE Pacific-day window [From, To] (inclusive, plain "yyyy-MM-dd" strings)
# and aggregate the TGL turnover rows. NO client-side date handling: the report's server-side From/To
# filter (DateType=2 = Job Creation Date) does all the Pacific-day bucketing, so this is identical on
# any host timezone. Returns @{ rev=[decimal]; total=[int]; sold=[int] }. FAIL LOUD: a report error or
# a missing JobType / EstimateSalesSubtotal column throws (never a silent $0).
function Get-SiloReportPeriod($Ctx, [string]$FromStr, [string]$ToStr) {
    $body = @{ parameters = @(
        @{ name='DateType'; value=2 },               # 2 = Job Creation Date = the turnover-call day
        @{ name='From'; value=$FromStr },            # PLAIN Pacific calendar date; the report windows internally
        @{ name='To';   value=$ToStr }
    ) }
    $rep = Invoke-StReport $Ctx $script:SILO_REV_REPORT_CAT $script:SILO_REV_REPORT_ID $body
    $col = Get-ReportColMap $rep.fields @('JobType','EstimateSalesSubtotal')
    $iType = $col['JobType']; $iSub = $col['EstimateSalesSubtotal']
    $acc = @{ rev=[decimal]0; total=0; sold=0 }
    foreach ($row in $rep.rows) {
        # JobType substring match ("TGL") is the VERIFIED source of truth for this metric - it
        # reproduces the manager's real target (18 jobs on 2026-08-03, 2,220 YTD vs the ~2,229
        # target), independently reproduced to the cent (2026-08-03 Today $72,713.62; 2026-07-29
        # $213,964.02 / 9 of 21). The report exposes no JobTypeId column, so there is no way to
        # filter against the canonical $script:SILO_EST_TGL id list here. Do NOT "optimize" this
        # to an id-based filter without re-verifying against those exact target numbers first.
        if ("$($row[$iType])" -notmatch 'TGL') { continue }        # turnover jobs only
        $sub = [decimal]$row[$iSub]                                # sold-only, pre-tax; 0 if nothing sold
        $acc.rev += $sub; $acc.total++
        if ($sub -gt 0) { $acc.sold++ }
    }
    $acc
}

function Get-Metric-SiloRevenue($Ctx, [datetime]$Date) {
    # $Date is the Pacific-selected snapshot date (the day the dashboard is viewed "as of"). Build the
    # three period windows straight from D's calendar components - NO timezone conversion of D, NO
    # client-side parsing of any report row. Each window is resolved server-side by the report.
    $y = $Date.Year; $m = $Date.Month; $d = $Date.Day
    $fmt = { param($yy,$mm,$dd) '{0:D4}-{1:D2}-{2:D2}' -f [int]$yy,[int]$mm,[int]$dd }   # zero-padded, culture-independent
    $dStr = & $fmt $y $m $d                            # D (Today upper bound; also MTD/YTD 'To')
    $windows = @{
        today = @{ from = $dStr;                  to = $dStr }   # From = To = D
        mtd   = @{ from = (& $fmt $y $m 1);        to = $dStr }   # 1st of D's month .. D
        ytd   = @{ from = (& $fmt $y 1 1);         to = $dStr }   # Jan 1 of D's year .. D
    }

    # THREE separate report pulls (Today / MTD / YTD), each server-side Pacific-day filtered.
    $per = @{}
    foreach ($p in 'today','mtd','ytd') {
        $per[$p] = Get-SiloReportPeriod $Ctx $windows[$p].from $windows[$p].to
    }

    $monthStart = [datetime]::new($y, $m, 1)          # for the MTD label only
    $yearStart  = [datetime]::new($y, 1, 1)           # for the YTD label only
    $lbls = @{
        today = "Today ($($Date.ToString('MMM d')))"
        mtd   = "Month to date ($($monthStart.ToString('MMM 1')) - $($Date.ToString('MMM d')))"
        ytd   = "Year to date ($($yearStart.ToString('MMM 1')) - $($Date.ToString('MMM d')))"
    }
    $revRows=@()
    foreach ($p in 'today','mtd','ytd') {
        $x = $per[$p]
        $revRows  += ,@($lbls[$p], (Format-Money $x.rev))
    }

    $notes = @(
        'SILO revenue = the SOLD / signed estimate subtotal (PRE-TAX) on turnover (TGL) jobs, credited to the TURNOVER-CALL DAY (the day the TGL job was created). Sold-only: a turnover with nothing sold contributes $0.',
        'Turnover (TGL) jobs only. Day boundaries are Pacific - the ServiceTitan report filters each period by the tenant''s (Pacific) calendar day server-side.',
        'NOT FINAL / RETROACTIVE BY DESIGN: an estimate sold later adds to its earlier turnover day, so Today, MTD and YTD can still rise. The full year is recomputed every refresh; this block is never frozen.'
    )

    @{ id='silo-revenue'; title='Revenue - SILO (sold/signed, pre-tax)'; status='ok'; error=$null;
       notes=$notes;
       tables=@(
         @{ subtitle='SILO revenue'; columns=@('Period','Revenue'); rows=$revRows; footer='' }
       ) }
}

# ============================================================================
#  M-HvacSalesSold: HVAC Sales SOLD / SIGNED revenue (on the Revenue tab), Today / MTD / YTD
#  WHAT IT IS: the pre-tax dollar value of HVAC systems the SALES TEAM actually SOLD - i.e. the
#  subtotal of SOLD estimates on the two HVAC Sales business units. This is deliberately NOT a
#  billed-invoice figure: sales dollars are invoiced later under Install, so a billed "Sales"
#  revenue reads a misleading ~$816/yr. This metric reads what was SOLD, not what was billed.
#  SCOPE (business units, decided by scope brief 2026-08-06):
#    370       = HVAC - Sales (NR)
#    340802904 = HVAC - Sales Costco (NR)
#  SOURCE (chosen after live investigation 2026-08-06 - see the block header note):
#    ServiceTitan sales/v2 estimates endpoint, filtered SERVER-SIDE by soldAfter / soldBefore
#    (the estimate's SOLD/deal-closed date, soldOn). Chosen over report 648754648 because ONLY the
#    estimates endpoint buckets by the true SOLD date: the report's DateType options bucket by job
#    creation / scheduled date, none of which match the sold-date total (verified: Aug 1-6 true
#    sold = $1,353,856.32 / 63 estimates; report best DateType gave $1,119,853.77 / 52). The
#    endpoint returns only status=Sold rows (only sold estimates carry a soldOn), pre-tax subtotal.
#  DATE BASIS: soldOn (the day the deal closed), server-side via soldAfter/soldBefore. A period =
#    a Pacific calendar window converted to a UTC range ONCE (Get-PacDateUtcIso). NO estimate's date
#    is ever parsed / bucketed in PowerShell -> provably identical on Windows PS5.1 and Linux/UTC
#    pwsh7 (this is the SILO platform-independence lesson applied).
#  BU SCOPING: the estimates endpoint SILENTLY IGNORES a businessUnitIds query param on this tenant
#    (verified live: returns all 9 BUs), so we filter by buId IN CODE. Verified 2026-08-06 that
#    filtering by the estimate's businessUnitId reproduces the job-business-unit scoping to the cent
#    (Aug 1-6: both = $1,353,856.32 / 63), i.e. a Sales-BU estimate lives on a Sales-BU job.
#  THREE server-side pulls (Today / MTD / YTD), same pattern as SILO revenue - never one pull
#    bucketed client-side. Recomputed every build; NEVER frozen (an estimate sold later lands on its
#    own earlier sold day, so past periods can still rise - correct, not a bug).
#  FAIL LOUD: any API error or missing field throws; a real $0 (no sales that period) is shown as
#    $0.00, distinct from an error tile.
# ============================================================================
$script:HVAC_SALES_BUS = [ordered]@{ '370'='Sales NR'; '340802904'='Sales Costco NR' }

# Pacific calendar date -> its UTC-midnight instant as an ISO string the estimates endpoint's
# soldAfter/soldBefore accept. Converts the PERIOD boundary once (TimeZoneInfo is cross-platform);
# this is server-side date filtering, NOT a per-record parse.
function Get-PacDateUtcIso($Ctx, [datetime]$PacDate) {
    ([TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($PacDate.Date,'Unspecified'), $Ctx.Pac)).ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
}

function Get-Metric-HvacSalesSold($Ctx, [datetime]$Date) {
    # Build the three sold-date windows straight from D's Pacific calendar, each [start, D+1):
    #   Today = D .. D+1 ; MTD = 1st-of-D's-month .. D+1 ; YTD = Jan 1 of D's year .. D+1.
    # The upper bound is the START of the day after D (exclusive), so D itself is fully included.
    $dStart      = $Date.Date
    $nextDay     = $dStart.AddDays(1)
    $monthStart  = [datetime]::new($Date.Year, $Date.Month, 1)
    $yearStart   = [datetime]::new($Date.Year, 1, 1)
    $endIso      = Get-PacDateUtcIso $Ctx $nextDay
    $windows = [ordered]@{
        today = @{ startIso = (Get-PacDateUtcIso $Ctx $dStart);     endIso = $endIso }
        mtd   = @{ startIso = (Get-PacDateUtcIso $Ctx $monthStart); endIso = $endIso }
        ytd   = @{ startIso = (Get-PacDateUtcIso $Ctx $yearStart);  endIso = $endIso }
    }

    # THREE server-side pulls; filter Sales BUs in code (server ignores businessUnitIds), sum [decimal].
    $tot = @{}                     # period -> bu -> [decimal]
    $cnt = @{}                     # period -> bu -> [int] (number of sold estimates, for context)
    foreach ($p in 'today','mtd','ytd') {
        $tot[$p]=@{}; $cnt[$p]=@{}
        foreach ($bu in $script:HVAC_SALES_BUS.Keys) { $tot[$p][$bu]=[decimal]0; $cnt[$p][$bu]=0 }
        $est = Get-SoldEstimates $Ctx $windows[$p].startIso $windows[$p].endIso
        foreach ($e in $est) {
            if (-not $script:HVAC_SALES_BUS.Contains($e.buId)) { continue }   # Sales BUs only, in code
            $tot[$p][$e.buId] += $e.subTotal
            $cnt[$p][$e.buId]++
        }
    }
    # cent-round each cell as [decimal]
    foreach ($p in 'today','mtd','ytd') { foreach ($bu in $script:HVAC_SALES_BUS.Keys) { $tot[$p][$bu] = [decimal][Math]::Round($tot[$p][$bu],2) } }

    $grp = @{}; $grpCnt=@{}
    foreach ($p in 'today','mtd','ytd') {
        $s=[decimal]0; $c=0
        foreach ($bu in $script:HVAC_SALES_BUS.Keys) { $s += $tot[$p][$bu]; $c += $cnt[$p][$bu] }
        $grp[$p]=$s; $grpCnt[$p]=$c
    }

    $lbls = @{
        today = "Today ($($Date.ToString('MMM d')))"
        mtd   = "Month to date ($($monthStart.ToString('MMM 1')) - $($Date.ToString('MMM d')))"
        ytd   = "Year to date ($($yearStart.ToString('MMM 1')) - $($Date.ToString('MMM d')))"
    }
    $summaryRows = @()
    foreach ($p in 'today','mtd','ytd') { $summaryRows += ,@($lbls[$p], (Format-Money $grp[$p])) }

    $buRows = @()
    foreach ($bu in $script:HVAC_SALES_BUS.Keys) {
        $buRows += ,@($script:HVAC_SALES_BUS[$bu], (Format-Money $tot['today'][$bu]), (Format-Money $tot['mtd'][$bu]), (Format-Money $tot['ytd'][$bu]))
    }
    $buFoot = "HVAC SALES TOTAL   Today {0}    MTD {1}    YTD {2}" -f (Format-Money $grp['today']), (Format-Money $grp['mtd']), (Format-Money $grp['ytd'])

    $notes = @(
        'HVAC Sales SOLD = the pre-tax subtotal of SOLD estimates on the two HVAC Sales units (Sales NR + Sales Costco NR), credited to the day the deal closed (the estimate''s sold date). What the sales team SOLD - open / unsold estimates are excluded.',
        'This is SOLD value, NOT billed: HVAC sales dollars are invoiced later under Install, so a billed "Sales" figure reads near-zero and is misleading. This figure is the sales team''s signed business.',
        'Distinct from Plumbing (billed invoices) and SILO (turnover sold value). Day boundaries are Pacific; the sold-date window is applied server-side so the figure is identical on any host timezone.',
        'NOT FINAL - Today, MTD and YTD are partial and keep rising as more estimates are sold; an estimate sold later lands on its own sold day. Recomputed every refresh; never frozen.'
    )

    @{ id='hvac-sales-sold'; title='Revenue - HVAC Sales (sold/signed, pre-tax)'; status='ok'; error=$null;
       notes=$notes;
       tables=@(
         @{ subtitle='HVAC Sales sold revenue'; columns=@('Period','Sold'); rows=$summaryRows; footer='' },
         @{ subtitle='By business unit'; columns=@('Business Unit','Today','MTD','YTD'); rows=$buRows; footer=$buFoot }
       ) }
}

# ============================================================================
#  M-SiloFlip: SILO flip rate = (TGLs created) / (ROPP calls ran) for TODAY + MTD + YTD
#  DEFINITION (the SILO manager's own definition, verified against live ServiceTitan 2026-08-10 -
#  see SILO-FLIP-HANDOFF.md, which is the spec this block implements):
#    flip rate = (TGLs created) / (ROPP calls ran)
#    * Numerator "TGLs created" = the ROW COUNT of saved report 642925621 (category 'technician',
#      "ROPP TGLS CREATED (JOHN)") for the period, run with DateType=3 so the report's own From/To
#      window applies to ScheduledDate server-side.
#    * Denominator "ROPP calls ran" = the ROW COUNT of saved report 379143819 (category
#      'accounting', "Johns Copy of Ericka's Revenue by Job Type") for the period, run with
#      DateType=1 so From/To applies to CompletionDate, AFTER the cleaning rules below drop
#      whole JobNumbers.
#    * Rollups are COUNT-WEIGHTED: sum(numerators) / sum(denominators). Percentages are NEVER
#      averaged (not per tech, not per BU, not per day).
#  WHY THIS REPLACED THE OLD 38.5% FLIP: the flip that used to live in M-SiloRevenue was
#    sold-estimate turnovers / total turnovers off report 648754648 - a different numerator AND a
#    different denominator, reading ~10 points below the manager's 48.4%. The owner's decision was
#    to match the manager exactly, so that table was DELETED (see the M-SiloRevenue header) and
#    this metric is now the single SILO flip figure. Two differently-defined numbers sharing one
#    name is worse than either alone.
#  CLEANING RULES (denominator ONLY), applied per DISTINCT JobNumber in EXACTLY this order, then
#  the ROWS belonging to kept JobNumbers are counted (handoff SS3):
#    1. JobNumber not in the jobs map at all -> KEEP (FAILS OPEN, counted as failedOpen)
#    2. else carries the Management Removed tag -> DROP
#    3. else does NOT carry the ROPP tag -> DROP
#    4. else jobStatus != 'Completed' AND the JobNumber is not in that period's TGL-source set
#       (i.e. it never appears in the numerator report) -> DROP
#    5. else KEEP
#    Job facts come from the JOBS API, never from the denominator report's own JobTags / Status
#    columns - substituting those would deviate from the manager's method (handoff SS8.8).
#    Fail loud ONLY if the lookup MECHANISM breaks (jobs API unreachable / shape changed); an
#    individual unresolvable JobNumber fails open by rule 1 and is counted, never thrown on.
#  ACCEPTED QUIRKS (knowingly copied from the manager, NOT bugs - do not "fix" them):
#    * ROW counting, not distinct jobs. YTD: 4873 rows vs 4848 distinct jobs (25 jobs carry more
#      than one invoice). Counting rows hits the manager's 4872; deduping misses it by ~24 and
#      recreates the divergence this metric exists to eliminate (handoff SS5.2 / SS8.2).
#    * The two sides key on DIFFERENT date fields (ScheduledDate vs CompletionDate). That is what
#      makes >100% reachable in small samples. Rates above 100% are LEGITIMATE and are neither
#      clamped nor hidden here - the manager's own dashboard renders 111.1% (handoff SS8.4).
#    * The cleaning rules are currently NO-OPS on live data (every denominator job resolved, all
#      ROPP-tagged, none Management-Removed, all Completed) because report 379143819 is already
#      pre-filtered. They are implemented faithfully anyway: if that report is ever edited the
#      DROP paths start mattering, and refresh-silo-flip.ps1 prints the per-rule drop counts every
#      recompute so such a change shows up instead of shifting the number silently (handoff SS5.1).
#  THREE PERIODS, ALWAYS, IN THIS ORDER: today, mtd, ytd - matching the order of the revenue cards
#    the dashboard stacks above this table, so the eye reads the same three periods down the page.
#    Windows are built from D (the Pacific snapshot date) as plain Pacific calendar strings:
#      today: From = To = D          mtd: From = D's 1st .. D          ytd: From = Jan 1 .. D
#    TODAY IS A SMALL SAMPLE and is therefore VOLATILE - on a 20-call day one TGL moves it several
#    points. It is a live indicator, not a settled number; MTD/YTD are the figures to judge by.
#  NO CLIENT-SIDE DATE PARSING ANYWHERE. Each period gets its OWN server-side windowed pull and we
#    count the rows the server returns. MTD is NEVER derived by filtering the YTD pull in code, and
#    neither is today. Client-side date parsing of report rows broke this project twice
#    cross-platform (PS5.1 keeps the report's offset, pwsh7-on-Linux normalizes to UTC) - handoff
#    SS7.2, SS8.5.
#  FAIL LOUD: a report id that no longer resolves surfaces as an HTTP error; a changed column
#    layout is caught by the STRICT ORDERED column check (count + name at every index) against
#    config's expectedColumns. Both reports are one person's personal copies, so a silent edit is
#    the likeliest failure mode and it must error on screen, never fall back to a stale number.
#  TWO COMPUTE PATHS, BECAUSE THE THREE PERIODS COST WILDLY DIFFERENT AMOUNTS:
#    * Compute-SiloFlip (FULL) = 6 report POSTs (num+den x ytd, mtd, today) spaced
#      postSpacingSeconds apart, plus ONE jobs pull over the whole YTD span (~42,000 jobs, reused
#      by all three periods - today's JobNumbers are a subset, so pulling twice would buy nothing
#      but 429 risk) => roughly 7-8 MINUTES.
#    * Compute-SiloFlipToday (CHEAP) = 2 report POSTs (num+den for today only) plus a NARROW
#      ONE-DAY jobs pull of a few hundred jobs => roughly 1-2 minutes. It recomputes today ONLY
#      and the caller carries the stored mtd/ytd forward verbatim.
#    Both hand their period data to the SAME builder, New-SiloFlipBlock, so the presentation
#    (labels, row order, formatting, notes, target) exists in exactly ONE place and the two paths
#    cannot drift apart.
#  TWO FRESHNESS CLOCKS, ONE PER PATH (both from config, enforced by refresh-silo-flip.ps1):
#    * cacheTtlSeconds (6h) gates the FULL rebuild. A YTD figure off ~4,900 calls barely moves in
#      six hours, and the rebuild is the expensive one.
#    * todayTtlSeconds (30m) gates the TODAY-ONLY rebuild. A daily figure goes stale in MINUTES,
#      and refreshing it alone is cheap, so it runs far more often. The snapshot therefore carries
#      TWO timestamps: generatedAt (when mtd/ytd were last built) and todayGeneratedAt (when today
#      was last built). A today-only run advances todayGeneratedAt and leaves generatedAt alone.
#  NOT IN $METRIC_DEFS ON PURPOSE, AND NOT COMPUTED IN serve.ps1: even the cheap path is minutes of
#    throttled POSTs, far too slow for a per-day snapshot or an on-demand request. It is a
#    current-state today/MTD/YTD figure served from its own cache file, exactly like
#    Build-SiloSnapshot -> data/silo-<month>.json. The cache is written by refresh-silo-flip.ps1,
#    which TTL-gates both paths (handoff SS6.2 / SS7.3).
#  TARGET IS CONFIG-DRIVEN: siloFlip.targetRate is emitted on the block as `target` so the
#    dashboard colour-codes against a number it READ rather than one written into the page. The
#    target must never be hard-coded here or in JS (CLAUDE.md rule 2) - not even inside a note
#    string, which is why the notes interpolate it.
#  NEVER FINAL: the figure is retroactive (TGLs keep being scheduled onto earlier days), so it
#    keeps settling upward and is never frozen.
# ============================================================================

# The block title. Used by the ok path, the error path and the error-snapshot helper, so it lives in
# one place - three copies of a long title string is how they end up disagreeing.
$script:SILO_FLIP_BLOCK_TITLE = 'SILO flip rate (TGLs created / ROPP calls ran)'

# Read + fully validate config.json -> siloFlip. Returns a plain hashtable with everything the
# metric needs, all strings normalized. NOTHING here has a default: every report id, category,
# DateType, column list and tag id must be present, or this throws a message naming the exact
# missing key. Get-DashConfig returns $null when config.json is absent OR unparseable, which is
# also a hard error - a flip rate computed off a guessed report id would be a fabricated number.
function Get-SiloFlipConfig {
    $cfg = Get-DashConfig
    if ($null -eq $cfg) { throw "config.json is missing or unparseable - the SILO flip metric reads its report ids, tag ids and timings from config.json siloFlip and has no defaults" }
    if ($null -eq $cfg.PSObject.Properties['siloFlip']) { throw "config.json is missing the siloFlip block" }
    $sf  = $cfg.siloFlip
    $out = @{}

    foreach ($side in 'numerator','denominator') {
        if ($null -eq $sf.PSObject.Properties[$side]) { throw "config.json is missing siloFlip.$side" }
        $spec = $sf.$side
        $o = @{}
        foreach ($k in 'reportId','category','dateColumn','jobNumberColumn') {
            if (($null -eq $spec.PSObject.Properties[$k]) -or [string]::IsNullOrWhiteSpace("$($spec.$k)")) { throw "config.json is missing siloFlip.$side.$k" }
            $o[$k] = "$($spec.$k)"
        }
        # dateType is a number and 0 could in principle be a valid enum value, so it is checked for
        # PRESENCE + integer-ness rather than truthiness (Is-EmptyVal would call 0 empty).
        if ($null -eq $spec.PSObject.Properties['dateType']) { throw "config.json is missing siloFlip.$side.dateType" }
        $dtRaw = "$($spec.dateType)"
        if ([string]::IsNullOrWhiteSpace($dtRaw)) { throw "config.json is missing siloFlip.$side.dateType" }
        $dtVal = 0
        if (-not [int]::TryParse($dtRaw, [ref]$dtVal)) { throw "config.json siloFlip.$side.dateType must be a whole number (got '$dtRaw')" }
        $o['dateType'] = $dtVal
        # expectedColumns is the columns-changed tripwire; an empty list would disable it silently.
        if ($null -eq $spec.PSObject.Properties['expectedColumns']) { throw "config.json is missing siloFlip.$side.expectedColumns" }
        $cols = @($spec.expectedColumns | ForEach-Object { "$_" })
        if ($cols.Count -eq 0) { throw "config.json has an empty siloFlip.$side.expectedColumns" }
        for ($i = 0; $i -lt $cols.Count; $i++) {
            if ([string]::IsNullOrWhiteSpace($cols[$i])) { throw "config.json siloFlip.$side.expectedColumns[$i] is empty" }
        }
        $o['expectedColumns'] = $cols
        # The two columns we index by name MUST be part of the declared layout, otherwise the two
        # config settings contradict each other and the mismatch would only show up mid-run.
        if ($cols -notcontains $o['dateColumn'])      { throw "config.json siloFlip.$side.dateColumn '$($o['dateColumn'])' is not listed in siloFlip.$side.expectedColumns" }
        if ($cols -notcontains $o['jobNumberColumn']) { throw "config.json siloFlip.$side.jobNumberColumn '$($o['jobNumberColumn'])' is not listed in siloFlip.$side.expectedColumns" }
        $out[$side] = $o
    }

    # Tag ids are kept as STRINGS because a job's tagTypeIds come back as numbers and every id in
    # this project is compared as a string (see Get-JobTypeMap et al).
    if ($null -eq $sf.PSObject.Properties['tags']) { throw "config.json is missing siloFlip.tags" }
    $tags = @{}
    foreach ($t in 'managementRemoved','ropp') {
        if (($null -eq $sf.tags.PSObject.Properties[$t]) -or [string]::IsNullOrWhiteSpace("$($sf.tags.$t)")) { throw "config.json is missing siloFlip.tags.$t" }
        $tags[$t] = "$($sf.tags.$t)"
    }
    $out['tags'] = $tags

    # targetRate: the flip-rate target the dashboard colour-codes each period against. Emitted on the
    # block as `target` so the number lives in config and NOWHERE in code - not in PowerShell, not in
    # JS, not even inside a note string (CLAUDE.md rule 2). Validated SEPARATELY from the durations
    # below because it is a PERCENTAGE, not a whole number of seconds: it may be fractional (59.5 is
    # a legal goal) and it has an upper bound. Out of range is a LOUD error with NO default - silently
    # falling back to some built-in target would be exactly the hard-coded goal the rule forbids.
    # Parsed with the INVARIANT culture on purpose: this file is read by Windows PS 5.1 here and by
    # pwsh7 on the Linux CI runner, and a culture-sensitive parse of "59.5" would disagree between
    # hosts if either ever ran under a comma-decimal locale.
    if ($null -eq $sf.PSObject.Properties['targetRate']) { throw "config.json is missing siloFlip.targetRate - the flip-rate target must come from config, never from code (CLAUDE.md rule 2)" }
    $trRaw = "$($sf.targetRate)"
    if ([string]::IsNullOrWhiteSpace($trRaw)) { throw "config.json is missing siloFlip.targetRate - the flip-rate target must come from config, never from code (CLAUDE.md rule 2)" }
    $trVal = 0.0
    if (-not [double]::TryParse($trRaw, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$trVal)) {
        throw "config.json siloFlip.targetRate must be a number (got '$trRaw')"
    }
    if (($trVal -le 0) -or ($trVal -gt 100)) { throw "config.json siloFlip.targetRate is a percentage and must be greater than 0 and at most 100 (got $trRaw)" }
    $out['targetRate'] = $trVal

    # postSpacingSeconds: the deliberate gap between report POSTs (tenant 429 cooldown is ~60s).
    # cacheTtlSeconds: how long the WHOLE cache (mtd/ytd) counts as fresh - the clock on the
    #   expensive 6-POST full rebuild (used by refresh-silo-flip.ps1).
    # todayTtlSeconds: the SEPARATE, much shorter clock on today's figure alone. A YTD figure off
    #   ~4,900 calls barely moves in six hours; a single day's figure is stale within minutes, and
    #   rebuilding just today costs 2 POSTs and a one-day jobs pull instead of 6 POSTs and a ~42k-job
    #   pull. Two clocks is what lets today be live without making the full rebuild frequent.
    # errorRetryCooldownSeconds: how long to leave a FAILED cache alone before retrying it. Without
    #   this, an errored cache is retried by every 15-minute CI run - 6 throttled report POSTs plus a
    #   ~42k-job pull each time, on top of the 3 report POSTs refresh.ps1 already makes in the same
    #   run - which is enough to keep the tenant 429-throttled instead of letting it recover.
    foreach ($k in 'postSpacingSeconds','cacheTtlSeconds','todayTtlSeconds','errorRetryCooldownSeconds') {
        if ($null -eq $sf.PSObject.Properties[$k]) { throw "config.json is missing siloFlip.$k" }
        $raw = "$($sf.$k)"
        if ([string]::IsNullOrWhiteSpace($raw)) { throw "config.json is missing siloFlip.$k" }
        $v = 0
        if (-not [int]::TryParse($raw, [ref]$v)) { throw "config.json siloFlip.$k must be a whole number of seconds (got '$raw')" }
        if ($v -le 0) { throw "config.json siloFlip.$k must be greater than 0 (got $v)" }
        $out[$k] = $v
    }
    $out
}

# Run ONE of the two reports for ONE period window [FromStr, ToStr] (plain Pacific "yyyy-MM-dd"
# strings; the report windows internally). Reuses the shared Invoke-StReport POST helper - which
# already does hasMore paging and the 429 retry/backoff - so no POST helper is duplicated here.
# FAIL LOUD, twice over:
#   * a deleted / renamed / no-longer-shared report surfaces as an HTTP error from the POST and is
#     rethrown WITH the report id + category, so the on-screen error says which report broke;
#   * STRICT ORDERED COLUMN VALIDATION: the returned field count must equal expectedColumns.Length
#     and the field NAME at every index must match expectedColumns[i] exactly (case-sensitive).
#     This is the tripwire for "John edited his report": adding, removing, renaming or REORDERING a
#     column all error here instead of silently shifting the number. Field objects expose .name
#     (same property Get-ReportColMap reads).
function Invoke-SiloFlipReport($Ctx, $Spec, [string]$FromStr, [string]$ToStr) {
    $body = @{ parameters = @(
        @{ name='DateType'; value=$Spec.dateType },   # per-report enum (3 = numerator, 1 = denominator); see config
        @{ name='From';     value=$FromStr },         # PLAIN Pacific calendar date; the report windows server-side
        @{ name='To';       value=$ToStr }
    ) }
    $rep = $null
    try { $rep = Invoke-StReport $Ctx $Spec.category $Spec.reportId $body }
    catch { throw "SILO flip: report $($Spec.reportId) (category $($Spec.category)) failed to run - $($_.Exception.Message)" }

    $fields = @($rep.fields)
    $exp    = @($Spec.expectedColumns)
    if ($fields.Count -ne $exp.Count) {
        throw "SILO flip: report $($Spec.reportId) (category $($Spec.category)) returned $($fields.Count) columns but config.json expects $($exp.Count) - the saved report was edited; update siloFlip expectedColumns after re-verifying the metric"
    }
    for ($i = 0; $i -lt $exp.Count; $i++) {
        $actual = "$($fields[$i].name)"
        if ($actual -cne $exp[$i]) {
            throw "SILO flip: report $($Spec.reportId) (category $($Spec.category)) column at index $i is '$actual' but config.json expects '$($exp[$i])' - the saved report was edited; update siloFlip expectedColumns after re-verifying the metric"
        }
    }
    $rep
}

# Window tripwire for ONE pull. Counts rows whose date-key cell falls outside the requested
# [From, To] window (inclusive on both ends, matching how the reports treat From/To).
# DELIBERATELY NOT [datetime]::Parse: that is the exact construct that broke this metric before -
# PS 5.1 preserves the offset the report emits while pwsh7-on-Linux normalizes the same string to
# UTC, so a Parse-based guard reaches DIFFERENT verdicts on the dev box and the CI runner and can
# false-positive at a period edge. Instead we regex a leading ISO yyyy-MM-dd out of the cell and
# compare those 10 characters as STRINGS with an ORDINAL comparison: ISO dates sort
# lexicographically, and an ordinal compare has no culture or host-timezone input at all.
# A cell with no ISO prefix (blank / an unexpected format) is counted as unparsed and is explicitly
# NOT treated as a violation - the guard must never be able to false-positive.
# Returns @{ outOfWindow=[int]; unparsed=[int] }.
function Measure-SiloFlipWindow($Rep, $Spec, [string]$FromStr, [string]$ToStr) {
    $col   = Get-ReportColMap $Rep.fields @($Spec.dateColumn)
    $iDate = $col[$Spec.dateColumn]
    $bad = 0; $unparsed = 0
    foreach ($row in $Rep.rows) {
        $m = [regex]::Match("$($row[$iDate])", '^(\d{4}-\d{2}-\d{2})')
        if (-not $m.Success) { $unparsed++; continue }
        $key = $m.Groups[1].Value
        if (([string]::CompareOrdinal($key, $FromStr) -lt 0) -or ([string]::CompareOrdinal($key, $ToStr) -gt 0)) { $bad++ }
    }
    @{ outOfWindow = $bad; unparsed = $unparsed }
}

# ---------- building blocks shared by BOTH compute paths --------------------------------------
# Everything below is factored out precisely because there are now TWO compute paths (the 6-POST
# full rebuild and the 2-POST today-only rebuild). The cleaning rules, the fail-loud window guard
# and the rate arithmetic exist ONCE each: two copies of the manager's rules would eventually
# disagree, and then today's figure and MTD's figure would be measuring different things.

# One period's server-side windowed pull of ONE report, plus the out-of-window tripwire.
# THROWS if any row's date key fell outside the requested window: that means the report's
# server-side From/To has stopped agreeing with the counted column, so the count cannot be trusted.
# This is the guard that caught the cross-platform date bug last time; both paths must have it.
# Returns @{ rep; outOfWindow; unparsed }.
function Get-SiloFlipPull($Ctx, $Spec, [string]$Period, [string]$FromStr, [string]$ToStr) {
    $rep = Invoke-SiloFlipReport $Ctx $Spec $FromStr $ToStr
    $chk = Measure-SiloFlipWindow $rep $Spec $FromStr $ToStr
    if ($chk.outOfWindow -gt 0) {
        throw "SILO flip: report $($Spec.reportId) returned $($chk.outOfWindow) row(s) whose $($Spec.dateColumn) falls outside the requested window $FromStr..$ToStr ($Period) - the report's server-side From/To no longer matches the counted column, so the count cannot be trusted"
    }
    @{ rep = $rep; outOfWindow = [int]$chk.outOfWindow; unparsed = [int]$chk.unparsed }
}

# The numerator IS the row count of the TGLs-created report for the period - no filtering, no date
# parsing. The same pull also yields that period's TGL-SOURCE SET (the JobNumbers that produced a
# TGL), which denominator cleaning rule 4 needs. Column located BY NAME, never by index.
# Returns @{ rows=[int]; tglSet=HashSet[string] }.
function Measure-SiloFlipNumerator($Rep, $Spec) {
    $iJob = (Get-ReportColMap $Rep.fields @($Spec.jobNumberColumn))[$Spec.jobNumberColumn]
    $set  = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($row in $Rep.rows) { [void]$set.Add("$($row[$iJob])") }
    @{ rows = [int](@($Rep.rows).Count); tglSet = $set }
}

# Bulk-pull jobs into a jobNumber (string) -> @{ jobStatus; tagTypeIds } map over the given query
# windows. TWO windows are always needed:
#   A) completedOnOrAfter/completedBefore - the population the denominator report reports on
#   B) createdOnOrAfter/createdBefore     - catches NON-completed TGL-source calls, which window A
#                                           cannot return but cleaning rule 4 must see
# The CALLER supplies the bounds, and that is the ONLY difference between the two paths' lookups:
# the full path spans Jan 1..D (~42,000 jobs), the today path spans D's single Pacific day (a few
# hundred). Paged at Invoke-StPaged's DEFAULT pageSize of 200 - NEVER 300 on this tenant
# (CLAUDE.md rule 7: byte-identical duplicate rows at exactly that value).
# FAIL LOUD only on a MECHANISM break (a missing field means the jobs API shape changed). An
# individual job we never see is a completely different thing and fails open via cleaning rule 1.
function Get-SiloFlipJobsMap($Ctx, $Queries) {
    $jobs = @{}
    foreach ($q in $Queries) {
        foreach ($j in (Invoke-StPaged $Ctx "/jpm/v2/tenant/$($Ctx.Tenant)/jobs" $q)) {
            foreach ($f in 'jobNumber','jobStatus','tagTypeIds') {
                if ($null -eq $j.PSObject.Properties[$f]) { throw "SILO flip: job $($j.id) is missing field '$f' - the jobs API shape changed" }
            }
            $key = "$($j.jobNumber)"
            if ([string]::IsNullOrWhiteSpace($key)) { $key = "$($j.id)" }   # this tenant has jobNumber == id
            if ($jobs.ContainsKey($key)) { continue }                       # the two windows overlap; first wins
            $tagIds = @()
            if ($j.tagTypeIds) { $tagIds = @($j.tagTypeIds | ForEach-Object { "$_" }) }
            $jobs[$key] = @{ jobStatus = "$($j.jobStatus)"; tagTypeIds = $tagIds }
        }
    }
    $jobs
}

# The denominator for ONE period: cleaning rules per DISTINCT JobNumber, then COUNT THE ROWS that
# belong to kept JobNumbers.
# Returns @{ den; rawRows; distinct; dropMgmt; dropNotRopp; dropNotCompletedNotTgl; failedOpen }.
function Measure-SiloFlipDenominator($Rep, $Spec, $Jobs, $TglSet, $Tags) {
    $iJob = (Get-ReportColMap $Rep.fields @($Spec.jobNumberColumn))[$Spec.jobNumberColumn]
    $rows = @($Rep.rows)
    $keep = @{}                       # JobNumber -> $true/$false, decided ONCE per distinct number
    $dropMgmt = 0; $dropNotRopp = 0; $dropNotCompletedNotTgl = 0; $failedOpen = 0
    foreach ($row in $rows) {
        $jn = "$($row[$iJob])"
        if ($keep.ContainsKey($jn)) { continue }
        # RULES 1-5 IN EXACTLY THIS ORDER (handoff SS3). Order matters: a Management-Removed job
        # is dropped before the ROPP test, and both run before the not-completed test.
        if (-not $Jobs.ContainsKey($jn)) {
            $keep[$jn] = $true; $failedOpen++                                   # 1. unresolvable -> KEEP (fails open)
        } elseif ($Jobs[$jn].tagTypeIds -contains $Tags.managementRemoved) {
            $keep[$jn] = $false; $dropMgmt++                                    # 2. Management Removed -> DROP
        } elseif ($Jobs[$jn].tagTypeIds -notcontains $Tags.ropp) {
            $keep[$jn] = $false; $dropNotRopp++                                 # 3. not ROPP-tagged -> DROP
        } elseif (($Jobs[$jn].jobStatus -ne 'Completed') -and (-not $TglSet.Contains($jn))) {
            $keep[$jn] = $false; $dropNotCompletedNotTgl++                      # 4. not Completed and never made a TGL -> DROP
        } else {
            $keep[$jn] = $true                                                  # 5. KEEP
        }
    }
    # DENOMINATOR = COUNT OF ROWS whose JobNumber was kept - deliberately NOT deduped to distinct
    # jobs. 25 jobs carry more than one invoice YTD, so row counting reads ~0.5% higher; that
    # inflation is exactly what makes this match the SILO manager's calls-ran (4873 vs their 4872,
    # where deduping gives 4848 and misses by ~24). Handoff SS5.2 / SS8.2.
    $den = 0
    foreach ($row in $rows) { if ($keep["$($row[$iJob])"]) { $den++ } }
    @{ den=[int]$den; rawRows=[int]$rows.Count; distinct=[int]$keep.Count;
       dropMgmt=[int]$dropMgmt; dropNotRopp=[int]$dropNotRopp;
       dropNotCompletedNotTgl=[int]$dropNotCompletedNotTgl; failedOpen=[int]$failedOpen }
}

# Assemble ONE period's public figures + diagnostics from its numerator and denominator results.
# rate is an UNROUNDED [double] and is NOT clamped: >100% is legitimate here because the two sides
# key on different date fields, and the manager renders such readings too. A zero denominator
# yields $null (rendered '-'), never a divide-by-zero and never a fake 0%.
# Returns @{ period=@{from;to;num;den;rate}; diag=@{...} }.
function New-SiloFlipPeriod([string]$FromStr, [string]$ToStr, $Num, $Den, [int]$OutOfWindow, [int]$Unparsed, [int]$JobsPulled) {
    $rate = $null
    if ($Den.den -gt 0) { $rate = [double](100.0 * $Num.rows / $Den.den) }
    @{
        period = @{ from=$FromStr; to=$ToStr; num=[int]$Num.rows; den=[int]$Den.den; rate=$rate }
        diag   = @{
            rawNumeratorRows                = [int]$Num.rows
            rawDenominatorRows              = [int]$Den.rawRows
            distinctJobNumbers              = [int]$Den.distinct
            droppedManagementRemoved        = [int]$Den.dropMgmt
            droppedNotRopp                  = [int]$Den.dropNotRopp
            droppedNotCompletedNotTglSource = [int]$Den.dropNotCompletedNotTgl
            failedOpen                      = [int]$Den.failedOpen
            outOfWindowRows                 = [int]$OutOfWindow
            unparsedDateRows                = [int]$Unparsed
            jobsPulled                      = [int]$JobsPulled
        }
    }
}

# ---------- the FULL compute path (all three periods) -----------------------------------------
# 6 report POSTs spaced postSpacingSeconds apart + ONE bulk jobs pull over the YTD span, then the
# cleaning rules => roughly 7-8 minutes. This is the expensive path; refresh-silo-flip.ps1 gates it
# on cacheTtlSeconds (6h).
# Returns @{ periods = [ordered]@{ today=@{from;to;num;den;rate}; mtd=@{...}; ytd=@{...} };
#            diagnostics = @{ today=@{...}; mtd=@{...}; ytd=@{...} };
#            target = <config siloFlip.targetRate> }
function Compute-SiloFlip($Ctx, [datetime]$Date) {
    $cfg = Get-SiloFlipConfig

    # All THREE windows are built from $Date's CALENDAR COMPONENTS only - no timezone conversion of
    # $Date, no client-side parsing anywhere. Same zero-padded, culture-independent idiom as
    # Get-Metric-SiloRevenue.
    $y = $Date.Year; $m = $Date.Month; $d = $Date.Day
    $fmt  = { param($yy,$mm,$dd) '{0:D4}-{1:D2}-{2:D2}' -f [int]$yy,[int]$mm,[int]$dd }
    $dStr = & $fmt $y $m $d                                   # D = the 'To' of all three periods
    $windows = [ordered]@{
        today = @{ from = $dStr;            to = $dStr }      # D .. D - one single Pacific day
        mtd   = @{ from = (& $fmt $y $m 1); to = $dStr }      # 1st of D's month .. D
        ytd   = @{ from = (& $fmt $y 1 1);  to = $dStr }      # Jan 1 of D's year .. D
    }

    # SIX POSTs, in this order, each its OWN server-side windowed pull. NEITHER mtd NOR today is
    # derived by filtering the ytd pull client-side (that would require parsing row dates -
    # forbidden, and it broke this project twice). Today is pulled LAST so its figure - the one
    # that moves - is the freshest of the three when the run finishes.
    # Start-Sleep BETWEEN pulls only: 5 sleeps, none before the first, none after the last. The
    # tenant 429-throttles rapid report runs with a ~60s backoff; this spacing is what avoids them,
    # and Invoke-StReportPost's Retry-After retry remains the backstop.
    $pulls = @(
        @{ period='ytd';   side='numerator' },
        @{ period='ytd';   side='denominator' },
        @{ period='mtd';   side='numerator' },
        @{ period='mtd';   side='denominator' },
        @{ period='today'; side='numerator' },
        @{ period='today'; side='denominator' }
    )
    $reps = @{}
    $oow  = @{ today=0; mtd=0; ytd=0 }   # out-of-window rows, summed over that period's two pulls
    $unp  = @{ today=0; mtd=0; ytd=0 }   # rows whose date cell had no ISO prefix (informational only)
    for ($i = 0; $i -lt $pulls.Count; $i++) {
        if ($i -gt 0) { Start-Sleep -Seconds $cfg.postSpacingSeconds }
        $p   = $pulls[$i]
        $w   = $windows[$p.period]
        $res = Get-SiloFlipPull $Ctx $cfg[$p.side] $p.period $w.from $w.to
        $oow[$p.period] += $res.outOfWindow
        $unp[$p.period] += $res.unparsed
        $reps["$($p.period)/$($p.side)"] = $res.rep
    }

    # ---- numerators: the row count IS "TGLs created", plus each period's TGL-source set.
    $nums = @{}
    foreach ($p in 'today','mtd','ytd') { $nums[$p] = Measure-SiloFlipNumerator $reps["$p/numerator"] $cfg.numerator }

    # ---- jobs map: ONE bulk pull covering the YTD span, reused for ALL THREE periods. The mtd and
    # today JobNumbers are SUBSETS of the ytd span, so pulling again for them would buy nothing but
    # 429 risk and minutes. Bounds are built the project-correct way: a Pacific day converted to a
    # UTC range ONCE via Get-PacDayWindow (Jan 1 for the start, D for the end, so D is fully
    # included).
    $yearStart = [datetime]::new($y, 1, 1)
    $startIso  = (Get-PacDayWindow $Ctx $yearStart).StartIso
    $endIso    = (Get-PacDayWindow $Ctx $Date).EndIso
    $jobs = Get-SiloFlipJobsMap $Ctx @(
        @{ completedOnOrAfter=$startIso; completedBefore=$endIso },
        @{ createdOnOrAfter=$startIso;   createdBefore=$endIso }
    )
    $jobsPulled = $jobs.Count

    # ---- denominators: cleaning rules per DISTINCT JobNumber, then count ROWS.
    $periods = [ordered]@{}; $diag = @{}
    foreach ($p in 'today','mtd','ytd') {
        $den = Measure-SiloFlipDenominator $reps["$p/denominator"] $cfg.denominator $jobs $nums[$p].tglSet $cfg.tags
        $one = New-SiloFlipPeriod $windows[$p].from $windows[$p].to $nums[$p] $den $oow[$p] $unp[$p] $jobsPulled
        $periods[$p] = $one.period
        $diag[$p]    = $one.diag
    }
    @{ periods = $periods; diagnostics = $diag; target = $cfg.targetRate }
}

# ---------- the CHEAP compute path (today only) ------------------------------------------------
# 2 report POSTs (numerator + denominator for D..D, one sleep between) plus a NARROW ONE-DAY jobs
# pull of a few hundred jobs instead of ~42,000 => roughly 1-2 minutes. That is what makes a
# 30-minute refresh of today's figure affordable while the full rebuild stays a 6-hourly event.
# Returns the SAME shape as Compute-SiloFlip but with only the `today` key; the caller carries the
# stored mtd/ytd forward.
# KNOWN, ACCEPTED DIFFERENCE FROM THE FULL PATH: this jobs map only spans D, so a denominator row
# whose job's completedOn/createdOn falls outside D's Pacific window is absent from the map and
# takes cleaning rule 1 - FAILS OPEN, i.e. is KEPT. The full path, whose map spans the year, would
# have resolved that job and applied rules 2-4 to it. Keeping it is the same verdict the rules
# reach on every live row today anyway (all ROPP-tagged, all Completed, none Management-Removed -
# handoff SS5.1), and `failedOpen` in the diagnostics is the observable that says how often it
# happened, so a real divergence shows up rather than hiding. The next full rebuild re-derives
# today with the full-year map regardless, so nothing is permanently skewed.
function Compute-SiloFlipToday($Ctx, [datetime]$Date) {
    $cfg = Get-SiloFlipConfig

    # Same calendar-components-only idiom as Compute-SiloFlip. From = To = D: exactly one Pacific
    # day, windowed SERVER-SIDE. Today is never carved out of the MTD/YTD rows in code.
    $fmt  = { param($yy,$mm,$dd) '{0:D4}-{1:D2}-{2:D2}' -f [int]$yy,[int]$mm,[int]$dd }
    $dStr = & $fmt $Date.Year $Date.Month $Date.Day
    $w    = @{ from = $dStr; to = $dStr }

    # TWO POSTs with ONE sleep BETWEEN them - none before the first, none after the last, same rule
    # as the full path. Two POSTs is one tenant-cooldown gap, not five.
    $numPull = Get-SiloFlipPull $Ctx $cfg.numerator   'today' $w.from $w.to
    Start-Sleep -Seconds $cfg.postSpacingSeconds
    $denPull = Get-SiloFlipPull $Ctx $cfg.denominator 'today' $w.from $w.to

    $num = Measure-SiloFlipNumerator $numPull.rep $cfg.numerator

    # ONE-DAY jobs pull: the same two windows the full path uses, but bounded to D's single Pacific
    # day via Get-PacDayWindow instead of the whole year. Default pageSize of 200 - NEVER 300.
    $day  = Get-PacDayWindow $Ctx $Date
    $jobs = Get-SiloFlipJobsMap $Ctx @(
        @{ completedOnOrAfter=$day.StartIso; completedBefore=$day.EndIso },
        @{ createdOnOrAfter=$day.StartIso;   createdBefore=$day.EndIso }
    )

    $den = Measure-SiloFlipDenominator $denPull.rep $cfg.denominator $jobs $num.tglSet $cfg.tags
    $one = New-SiloFlipPeriod $w.from $w.to $num $den `
             ($numPull.outOfWindow + $denPull.outOfWindow) ($numPull.unparsed + $denPull.unparsed) $jobs.Count

    @{ periods = [ordered]@{ today = $one.period }; diagnostics = @{ today = $one.diag }; target = $cfg.targetRate }
}

# ---------- presentation: the ONE place period data becomes a block ----------------------------
# BOTH compute paths funnel through here, and that is the entire point of the refactor: a full
# rebuild and a today-only rebuild must emit IDENTICAL structure, labels, row order, formatting and
# notes, or the tile would visibly change shape depending on which path happened to run last.
# $Periods and $Diagnostics are CONTAINERS keyed today/mtd/ytd (a hashtable or [ordered] hashtable).
# Their VALUES may be hashtables fresh out of a compute OR ConvertFrom-Json objects carried forward
# from the existing cache, so each period's fields are read with plain dot access - which resolves a
# key on a hashtable and a property on a PSCustomObject, identically on PS 5.1 and pwsh7.
# ROWS ARE ALWAYS EXACTLY THREE, in today/mtd/ytd order - the same order as the revenue cards
# stacked above this table, so the eye reads the same three periods down the page. A missing period
# THROWS rather than yielding a short table: a silently two-row table is how a broken period gets
# mistaken for "there was no data".
function New-SiloFlipBlock($Periods, $Diagnostics, $Target, [datetime]$Date) {
    # Verbose period labels, same style as the revenue blocks: "Month to date (Aug 1 - Aug 11)".
    $monthStart = [datetime]::new($Date.Year, $Date.Month, 1)
    $yearStart  = [datetime]::new($Date.Year, 1, 1)
    $lbls = @{
        today = "Today ($($Date.ToString('MMM d')))"
        mtd   = "Month to date ($($monthStart.ToString('MMM 1')) - $($Date.ToString('MMM d')))"
        ytd   = "Year to date ($($yearStart.ToString('MMM 1')) - $($Date.ToString('MMM d')))"
    }

    $rows = @(); $outPer = @{}; $outDiag = @{}
    foreach ($p in 'today','mtd','ytd') {
        $x = $Periods[$p]
        if ($null -eq $x)     { throw "SILO flip: period '$p' is missing - the block always reports today, mtd and ytd" }
        if ($null -eq $x.num) { throw "SILO flip: period '$p' has no num (TGLs created)" }
        if ($null -eq $x.den) { throw "SILO flip: period '$p' has no den (calls ran)" }
        $dg = $Diagnostics[$p]
        if ($null -eq $dg)    { throw "SILO flip: period '$p' has no diagnostics - the per-rule drop counts must stay observable (handoff SS5.1)" }
        # rate is $null when the denominator was 0 -> '-' , never a fake 0%. A rate above 100% is
        # legitimate here and is printed as-is, NOT clamped.
        $pct = '-'
        if ($null -ne $x.rate) { $pct = "{0:N1}%" -f $x.rate }
        $rows       += ,@($lbls[$p], $pct, "$($x.num) / $($x.den)")
        $outPer[$p]  = @{ num=[int]$x.num; den=[int]$x.den; rate=$x.rate }
        $outDiag[$p] = $dg
    }

    # The target is INTERPOLATED into the note rather than typed out, because writing the number
    # into this string would be hard-coding the goal in code (CLAUDE.md rule 2) just as surely as
    # writing it into the comparison would.
    $notes = @(
        'Flip rate = TGLs created / ROPP calls ran, per period - the SILO manager''s own definition. The counts behind each % are shown as "TGLs / calls ran". This REPLACED the older flip figure (turnovers that sold an estimate / total turnovers), which was a different measurement roughly 10 points lower.',
        'Rollups are COUNT-WEIGHTED: the period rate is total TGLs / total calls ran. Percentages are never averaged together (not per tech, not per day) - averaging percentages would weight a 3-call day the same as a 300-call day.',
        'TODAY IS A LIVE INDICATOR, NOT A SETTLED NUMBER. It is one day''s worth of calls - often only a few dozen - so a handful of calls swings it many points: 2 TGLs on 3 calls reads 66.7% and the next call can move it 15 points either way. Watch it to see how today is going; judge performance on month-to-date and year-to-date, which have the volume to be stable.',
        'The calls-ran count counts invoice ROWS, not distinct jobs, so the ~25 jobs a year carrying more than one invoice are counted more than once. That inflates calls ran by about 0.5% and is deliberate: it is what makes this figure match the SILO manager''s number instead of drifting ~24 calls below it.',
        'The two sides are dated on different fields - TGLs by the job''s scheduled date, calls ran by the invoice''s completion date - so a short period can show MORE TGLs than calls ran and read above 100%. That is faithful to the source reports, not a bug, and is shown as-is rather than capped at 100%.',
        "The target each period is measured against is $Target% and is read from config.json (siloFlip.targetRate) when the figure is built - it is deliberately NOT written into this code or into the dashboard page, so moving the goal is a one-number edit in config.json with no code change.",
        'NOT FINAL / RETROACTIVE BY DESIGN: TGLs keep getting scheduled onto days already counted, so every figure here keeps settling upward after the fact. Nothing is ever frozen; each recompute replaces the whole figure.'
    )

    @{ id='silo-flip'; title=$script:SILO_FLIP_BLOCK_TITLE; status='ok'; error=$null; target=$Target;
       notes=$notes;
       periods=$outPer;
       tables=@(
         @{ subtitle='Flip rate'; columns=@('Period','Flip Rate','TGLs / calls ran'); rows=$rows;
            footer=("As of $($Date.ToString('MMM d, yyyy')) - partial and still settling (TGLs are scheduled retroactively).") }
       );
       diagnostics=$outDiag }
}

# Build the block for a FULL rebuild. Same shape every other Get-Metric-* returns (id/title/status/
# error/notes/tables) plus `target`, `periods` + `diagnostics`, which the SILO-flip renderer reads.
function Get-Metric-SiloFlip($Ctx, [datetime]$Date) {
    $res = Compute-SiloFlip $Ctx $Date
    New-SiloFlipBlock $res.periods $res.diagnostics $res.target $Date
}

# The configured target, or $null when config itself is the thing that broke. Used on the ERROR
# path only: `target` must be present in EVERY emitted block so the renderer can index it without a
# guard, and when Get-SiloFlipConfig is what threw there is no target to report. $null says
# "unknown", which is honest; a built-in fallback would be exactly the hard-coded goal CLAUDE.md
# rule 2 forbids.
function Get-SiloFlipTarget {
    try { return (Get-SiloFlipConfig).targetRate } catch { return $null }
}

# The ERROR envelope, in ONE place, so a full-rebuild failure and a today-only failure write
# structurally identical files - refresh-silo-flip.ps1 calls this for the today-only path, which is
# what lets the error-retry cooldown govern both the same way.
# `final` is ALWAYS $false - this metric is retroactive, so it is never frozen. BOTH timestamps are
# set to now: there is no usable figure left to date separately, and dating them apart would let a
# stale-looking today clock trigger a today-only retry against a cache with no mtd/ytd to reuse.
function New-SiloFlipErrorSnapshot {
    param([datetime]$Date, [string]$Message)
    $b = New-ErrorBlock 'silo-flip' $script:SILO_FLIP_BLOCK_TITLE $Message
    # Keep the key set stable across ok/error so a renderer can index these without a guard.
    $b.periods = @{}; $b.diagnostics = @{}; $b.target = (Get-SiloFlipTarget)
    $now = Get-UtcNow
    @{ asOf=$Date.ToString('yyyy-MM-dd'); final=$false; generatedAt=$now; todayGeneratedAt=$now; block=$b }
}

# FULL cache-file wrapper, mirroring Build-SiloSnapshot: build all three periods, and on ANY failure
# store a status='error' block instead of a number (fail loud on screen, never a stale figure).
# ONE timestamp serves both clocks here: a full rebuild just rebuilt all three periods, so today's
# figure and the mtd/ytd figures are exactly as old as each other.
function Build-SiloFlipSnapshot {
    param($Ctx, [datetime]$Date)
    $b = $null
    try { $b = Get-Metric-SiloFlip $Ctx $Date }
    catch { return (New-SiloFlipErrorSnapshot $Date ("$($_.Exception.Message)")) }
    $now = Get-UtcNow
    @{ asOf=$Date.ToString('yyyy-MM-dd'); final=$false; generatedAt=$now; todayGeneratedAt=$now; block=$b }
}

# TODAY-ONLY cache-file wrapper: recompute TODAY (2 POSTs + a one-day jobs pull) and carry the
# EXISTING cache's mtd/ytd periods and diagnostics forward VERBATIM. Emits the same envelope as
# Build-SiloFlipSnapshot, so the file the dashboard reads is indistinguishable in shape.
# THE TWO TIMESTAMPS ARE THE WHOLE POINT: generatedAt keeps the EXISTING value because mtd/ytd did
# NOT change - re-dating them to "now" would restart the 6-hour clock on every 30-minute today run
# and the expensive full rebuild would then never happen again. todayGeneratedAt is now.
# THIS THROWS INSTEAD OF CATCHING, on purpose, in two situations:
#   * the existing cache has no healthy mtd/ytd to carry forward. Inventing zeros would put a
#     fabricated number on the wall (CLAUDE.md rule 1), and quietly promoting itself to a full
#     recompute would hide a broken cache. The CALLER decides: full recompute, or error block.
#   * the today pull itself fails. The caller records that with New-SiloFlipErrorSnapshot, exactly
#     as a full failure is recorded, so the error-retry cooldown then governs the retry.
function Build-SiloFlipTodaySnapshot {
    param($Ctx, [datetime]$Date, $ExistingCache)
    if ($null -eq $ExistingCache) { throw "SILO flip today-only: no existing cache was passed - there are no MTD/YTD figures to carry forward" }
    $eb = $ExistingCache.block
    if ($null -eq $eb) { throw "SILO flip today-only: the existing cache has no block - nothing to carry forward" }
    if ("$($eb.status)" -ne 'ok') { throw "SILO flip today-only: the existing cache holds a status='$($eb.status)' block, so it has no MTD/YTD figures to carry forward" }
    $ep = $eb.periods; $ed = $eb.diagnostics
    # num/den are checked for NULL, not for truthiness: a genuine 0 must pass (a day with no calls
    # ran is real data), and Is-EmptyVal would call it missing.
    foreach ($p in 'mtd','ytd') {
        if (($null -eq $ep) -or ($null -eq $ep.$p) -or ($null -eq $ep.$p.num) -or ($null -eq $ep.$p.den)) {
            throw "SILO flip today-only: the existing cache has no healthy '$p' period to carry forward"
        }
        if (($null -eq $ed) -or ($null -eq $ed.$p)) {
            throw "SILO flip today-only: the existing cache has no '$p' diagnostics to carry forward"
        }
    }
    # generatedAt must be carried forward as the SAME INSTANT on both hosts. Windows PS 5.1's
    # ConvertFrom-Json coerces an ISO-8601 string into a LOCAL [datetime] while pwsh7 leaves it a
    # [string], so normalize whatever the host handed us into a UTC "o" string rather than trusting
    # the host's typing - the same coercion trap refresh-silo-flip.ps1's raw-text regex reads avoid.
    $prevGen = $ExistingCache.generatedAt
    if ($prevGen -is [datetime]) { $prevGen = ([datetime]$prevGen).ToUniversalTime().ToString('o') }
    else { $prevGen = "$prevGen" }
    if ([string]::IsNullOrWhiteSpace($prevGen)) { throw "SILO flip today-only: the existing cache has no generatedAt, so the MTD/YTD age cannot be carried forward" }
    try { [void](Parse-Utc $prevGen) } catch { throw "SILO flip today-only: the existing cache's generatedAt '$prevGen' is unparseable, so the MTD/YTD age cannot be carried forward" }

    $res     = Compute-SiloFlipToday $Ctx $Date
    $periods = @{ today = $res.periods['today'];     mtd = $ep.mtd; ytd = $ep.ytd }
    $diag    = @{ today = $res.diagnostics['today']; mtd = $ed.mtd; ytd = $ed.ytd }
    $b       = New-SiloFlipBlock $periods $diag $res.target $Date
    @{ asOf=$Date.ToString('yyyy-MM-dd'); final=$false; generatedAt=$prevGen; todayGeneratedAt=(Get-UtcNow); block=$b }
}

# ---------- registry + snapshot assembler ----------
# NOTE: silo-flip is deliberately ABSENT from $METRIC_DEFS. It is not a per-day snapshot metric -
# it is a current-state today/MTD/YTD figure whose full rebuild costs ~7-8 minutes of throttled
# report POSTs (and even the today-only rebuild costs 1-2), so it is built by refresh-silo-flip.ps1
# into its own cache file on two separate TTLs (same pattern as Build-SiloSnapshot).
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
    @{ id='silo-revenue';   title='Revenue - SILO';           act={ param($c,$d) Get-Metric-SiloRevenue   $c $d } },
    @{ id='hvac-sales-sold'; title='Revenue - HVAC Sales';    act={ param($c,$d) Get-Metric-HvacSalesSold $c $d } }
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
