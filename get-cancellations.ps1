# ============================================================================
#  get-cancellations.ps1  (M2 - rebuilt 2026-07-16)
#  CANCELLATIONS per business unit for ONE Pacific day = the dispatch board's
#  "cancel tray" for that day. Prints numbers + per-cancellation detail.
#
#  Follows SPEC.md (M2), per Troy's 2026-07-16 decisions:
#    - A cancellation belongs to the day it was SCHEDULED FOR SERVICE
#      (the appointment's start), NOT the day it was cancelled.
#    - Source = appointments with status=Canceled whose start is in the Pacific day.
#    - Business unit comes from the appointment's job.
#    - Per cancellation, also show: when it cancelled, why (reason), who cancelled
#      (from jobs/{id}/canceled-log -> createdOn, reasonId, memo, createdById;
#       reasonId resolved via job-cancel-reasons; createdById via employees/technicians).
#    - All 9 trade business units. Inventory (208554530) excluded.
#    - Pages through EVERY page. Fails loud on API error / missing field.
#
#  NOT marked verified. Caveat printed re: appointment-cancel vs job-cancel.
#
#  Usage:  .\get-cancellations.ps1  [-Date yyyy-MM-dd]   (default = yesterday)
# ============================================================================

[CmdletBinding()]
param([string]$Date)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Fail($msg) { Write-Host ""; Write-Host "FAILED: $msg" -ForegroundColor Red; Write-Host ""; exit 1 }

$BUSINESS_UNITS = [ordered]@{
    '333'='HVAC - Service'; '337'='HVAC - Install - AOR'; '342817560'='HVAC - Maintenance'
    '370'='HVAC - Sales (NR)'; '340802904'='HVAC - Sales Costco (NR)'
    '353'='Plumbing - Service'; '354'='Plumbing - Maintenance'; '408662213'='Plumbing - Install'
    '595105985'='Plumbing - Drains'
}

$TokenUrl = 'https://auth.servicetitan.io/connect/token'
$ApiBase  = 'https://api.servicetitan.io'

try { $pac = [TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time') }
catch { Fail "Could not load the 'Pacific Standard Time' zone. $($_.Exception.Message)" }

function Parse-Utc([string]$s) {
    return [DateTime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture,
        ([Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal))
}
function To-PacStr([string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    return ([TimeZoneInfo]::ConvertTimeFromUtc((Parse-Utc $s), $pac)).ToString('yyyy-MM-dd HH:mm')
}
function Is-Empty($v) {
    if ($null -eq $v) { return $true }
    if (($v -is [string]) -and ($v.Trim() -eq '')) { return $true }
    if (($v -is [int] -or $v -is [long] -or $v -is [double]) -and ($v -eq 0)) { return $true }
    return $false
}

if ([string]::IsNullOrWhiteSpace($Date)) {
    $selected = ([TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $pac)).Date.AddDays(-1)
} else {
    try { $selected = [DateTime]::ParseExact($Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    catch { Fail "Date '$Date' is not valid. Use yyyy-MM-dd." }
}
$startLocal = [DateTime]::SpecifyKind($selected.Date, 'Unspecified')
$startUtc = [TimeZoneInfo]::ConvertTimeToUtc($startLocal, $pac)
$endUtc   = [TimeZoneInfo]::ConvertTimeToUtc($startLocal.AddDays(1), $pac)
$startIso = $startUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
$endIso   = $endUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")

$secretsPath = Join-Path $PSScriptRoot 'secrets.json'
if (-not (Test-Path $secretsPath)) { Fail "secrets.json not found next to this script." }
try { $secrets = Get-Content $secretsPath -Raw | ConvertFrom-Json } catch { Fail "secrets.json is not valid JSON: $($_.Exception.Message)" }
foreach ($f in 'clientId','clientSecret','appKey','tenantId') {
    if ([string]::IsNullOrWhiteSpace($secrets.$f)) { Fail "secrets.json is missing '$f'." }
}
$tenant = $secrets.tenantId

try {
    $tokenResp = Invoke-RestMethod -Method Post -Uri $TokenUrl -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type='client_credentials'; client_id=$secrets.clientId; client_secret=$secrets.clientSecret }
} catch { $st = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'n/a' }; Fail "Token request failed (HTTP $st): $($_.Exception.Message)" }
$token = $tokenResp.access_token
if ([string]::IsNullOrWhiteSpace($token)) { Fail "Auth server did not return an access token." }
$headers = @{ 'Authorization' = "Bearer $token"; 'ST-App-Key' = $secrets.appKey }

function Get-AllPages($path, [hashtable]$params) {
    $all = New-Object System.Collections.ArrayList
    $page = 1; $maxPages = 1000
    while ($true) {
        $pairs = @()
        foreach ($k in $params.Keys) { $pairs += ("{0}={1}" -f $k, [uri]::EscapeDataString([string]$params[$k])) }
        $pairs += "pageSize=200"; $pairs += "page=$page"
        $url = "$ApiBase$path" + "?" + ($pairs -join '&')
        try { $resp = Invoke-RestMethod -Method Get -Uri $url -Headers $headers }
        catch {
            $st = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'n/a' }
            $body = ''; if ($_.Exception.Response) { try { $body = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {} }
            Fail "API call failed (HTTP $st) on GET $path (page $page). $body"
        }
        if ($null -eq $resp.PSObject.Properties['data']) { Fail "Unexpected response from $path - no 'data' field." }
        if ($resp.data) { [void]$all.AddRange(@($resp.data)) }
        if (-not $resp.hasMore) { break }
        $page++; if ($page -gt $maxPages) { Fail "Paging exceeded $maxPages pages on $path." }
    }
    return ,$all
}

# --- catalogs: cancel reasons + user names ---
$reasonName = @{}
foreach ($r in (Get-AllPages "/jpm/v2/tenant/$tenant/job-cancel-reasons" @{})) { $reasonName["$($r.id)"] = $r.name }
$userName = @{}
foreach ($e in (Get-AllPages "/settings/v2/tenant/$tenant/employees" @{}))   { $userName["$($e.id)"] = $e.name }
foreach ($e in (Get-AllPages "/settings/v2/tenant/$tenant/technicians" @{})) { if (-not $userName.ContainsKey("$($e.id)")) { $userName["$($e.id)"] = $e.name } }
$jobTypeName = @{}
foreach ($jt in (Get-AllPages "/jpm/v2/tenant/$tenant/job-types" @{})) { $jobTypeName["$($jt.id)"] = $jt.name }

# --- canceled appointments scheduled that day ---
$appts = Get-AllPages "/jpm/v2/tenant/$tenant/appointments" @{ startsOnOrAfter=$startIso; startsBefore=$endIso }
$cxAppts = New-Object System.Collections.ArrayList
$jobIds  = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($a in $appts) {
    if ($null -eq $a.PSObject.Properties['status']) { Fail "Appointment $($a.id) is missing status." }
    if ($a.status -ne 'Canceled') { continue }
    if ($null -eq $a.PSObject.Properties['start']) { Fail "Appointment $($a.id) is missing start." }
    $ts = Parse-Utc $a.start
    if (-not ($ts -ge $startUtc -and $ts -lt $endUtc)) { continue }
    if ($null -eq $a.PSObject.Properties['jobId']) { Fail "Appointment $($a.id) is missing jobId." }
    if (Is-Empty $a.jobId) { Fail "Canceled appointment $($a.id) has an empty jobId." }
    [void]$cxAppts.Add($a); [void]$jobIds.Add("$($a.jobId)")
}

# --- fetch those jobs (for businessUnitId) ---
$jobMap = @{}
$idList = @($jobIds); $chunk = 50
for ($i = 0; $i -lt $idList.Count; $i += $chunk) {
    $slice = $idList[$i..([Math]::Min($i + $chunk - 1, $idList.Count - 1))]
    foreach ($j in (Get-AllPages "/jpm/v2/tenant/$tenant/jobs" @{ ids = ($slice -join ',') })) { $jobMap["$($j.id)"] = $j }
}
$missing = @($idList | Where-Object { -not $jobMap.ContainsKey($_) })
if ($missing.Count -gt 0) { Fail "$($missing.Count) job id(s) for canceled appointments could not be fetched (e.g. $($missing[0]))." }

# --- tally per BU + build detail rows ---
$canceled = @{}; foreach ($id in $BUSINESS_UNITS.Keys) { $canceled[$id] = 0 }
$logCache = @{}   # jobId -> latest active canceled-log entry (or $null)
$details = New-Object System.Collections.ArrayList
$noLog = 0

foreach ($a in $cxAppts) {
    $jid = "$($a.jobId)"
    $job = $jobMap[$jid]
    if ($null -eq $job.PSObject.Properties['businessUnitId']) { Fail "Job $jid is missing businessUnitId." }
    $bu = "$($job.businessUnitId)"
    if (-not $BUSINESS_UNITS.Contains($bu)) { continue }
    $canceled[$bu]++

    $jt = if (($null -ne $job.PSObject.Properties['jobTypeId']) -and $jobTypeName.ContainsKey("$($job.jobTypeId)")) { $jobTypeName["$($job.jobTypeId)"] } else { "jobType $($job.jobTypeId)" }

    if (-not $logCache.ContainsKey($jid)) {
        $log = Get-AllPages "/jpm/v2/tenant/$tenant/jobs/$jid/canceled-log" @{}
        $entry = $log | Where-Object { $_.active } | Sort-Object { Parse-Utc $_.createdOn } | Select-Object -Last 1
        if (-not $entry) { $entry = $log | Sort-Object { Parse-Utc $_.createdOn } | Select-Object -Last 1 }
        $logCache[$jid] = $entry
    }
    $entry = $logCache[$jid]
    if ($entry) {
        $rn = if ($entry.reasonId -and $reasonName.ContainsKey("$($entry.reasonId)")) { $reasonName["$($entry.reasonId)"] } else { "reason $($entry.reasonId)" }
        $who = if ($entry.createdById -and $userName.ContainsKey("$($entry.createdById)")) { $userName["$($entry.createdById)"] } else { "user $($entry.createdById)" }
        $memo = "$($entry.memo)" -replace '\s+', ' '
        if ($memo.Length -gt 45) { $memo = $memo.Substring(0,45) + '...' }
        $cancelledAt = To-PacStr $entry.createdOn
    } else {
        $noLog++
        $rn = '(no cancel-log - job not fully canceled?)'; $who = ''; $memo = ''; $cancelledAt = ''
    }
    [void]$details.Add([PSCustomObject]@{
        'Business Unit' = $BUSINESS_UNITS[$bu]
        'Job Type'      = $jt
        'Scheduled'     = To-PacStr $a.start
        'Cancelled'     = $cancelledAt
        'Reason'        = $rn
        'By'            = $who
        'Note'          = $memo
    })
}

# --- output ---
Write-Host ""
Write-Host "CANCELLATIONS (dispatch-board cancel tray)" -ForegroundColor Cyan
Write-Host "Pacific day : $($selected.ToString('yyyy-MM-dd')) (America/Los_Angeles) - dated by SCHEDULED-for-service"
Write-Host "UTC window  : $startIso  ..  $endIso"
Write-Host "Appointments scanned: $($appts.Count); canceled scheduled this day: $($cxAppts.Count)"
Write-Host ""

$rows = foreach ($id in $BUSINESS_UNITS.Keys) {
    [PSCustomObject]@{ 'Business Unit' = $BUSINESS_UNITS[$id]; 'Canceled' = $canceled[$id] }
}
$rows | Format-Table -AutoSize | Out-String | Write-Host

$total = ($canceled.Values | Measure-Object -Sum).Sum; if ($null -eq $total) { $total = 0 }
Write-Host ("TOTAL 9 units, Inventory excluded    Canceled: {0}" -f $total) -ForegroundColor Green
Write-Host ""
if ($details.Count -gt 0) {
    Write-Host "Detail (per cancellation):" -ForegroundColor Cyan
    foreach ($d in $details) {
        Write-Host ("  {0,-22} {1}  (by {2})" -f $d.'Business Unit', $d.'Job Type', $d.By)
        $line = "        sched $($d.Scheduled)  cancelled $($d.Cancelled)  reason: $($d.Reason)"
        if ($d.Note) { $line += "  | $($d.Note)" }
        Write-Host $line -ForegroundColor DarkGray
    }
    Write-Host ""
}
if ($noLog -gt 0) {
    Write-Host "CAVEAT: $noLog cancellation(s) had NO cancel-log entry - likely the appointment was canceled but the" -ForegroundColor Yellow
    Write-Host "job was only rescheduled (not fully canceled). Reason/when/who are blank for those. Confirm with Troy" -ForegroundColor Yellow
    Write-Host "whether reschedule-cancellations belong in the cancel tray (SPEC M2 open sub-question)." -ForegroundColor Yellow
    Write-Host ""
}
