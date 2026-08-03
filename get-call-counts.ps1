# ============================================================================
#  get-call-counts.ps1
#  First metric: CALL COUNT per business unit - BOOKED and COMPLETED - for ONE day.
#  Prints numbers to screen. No dashboard, no web page.
#
#  Follows SPEC.md (M1) exactly:
#    - "A day" = a Pacific (America/Los_Angeles) calendar day, converted to a UTC
#      window for the API. Never buckets by raw UTC date.
#    - A job counts as a "call" (new opportunity) only if, on the JOB record:
#        recallForId is empty AND warrantyId is empty AND the job type NAME does
#        not match  recall | warranty | part.*install  (case-insensitive).
#    - BOOKED    = qualifying jobs SCHEDULED FOR the day = jobs with a non-canceled appointment
#                  whose start falls in the Pacific day (the calls on the dispatch board that day).
#    - COMPLETED = qualifying jobs whose completedOn falls in the Pacific day AND jobStatus=Completed.
#    - All 9 trade business units, shown separately. Inventory (208554530) excluded.
#    - Pages through EVERY page - never trusts page 1.
#
#  Fails loud: any API error, any job type it can't resolve, any missing field it
#  needs - it STOPS and says exactly what went wrong. It never prints a guessed number.
#
#  Usage:
#    .\get-call-counts.ps1                 # defaults to yesterday (Pacific)
#    .\get-call-counts.ps1 -Date 2026-07-15
# ============================================================================

[CmdletBinding()]
param(
    [string]$Date   # Pacific calendar day, format yyyy-MM-dd. Omit = yesterday.
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Fail($msg) {
    Write-Host ""
    Write-Host "FAILED: $msg" -ForegroundColor Red
    Write-Host ""
    exit 1
}

# --- The 9 reported business units (SPEC.md). Inventory 208554530 is NOT here. ---
$BUSINESS_UNITS = [ordered]@{
    '333'       = 'HVAC - Service'
    '337'       = 'HVAC - Install - AOR'
    '342817560' = 'HVAC - Maintenance'
    '370'       = 'HVAC - Sales (NR)'
    '340802904' = 'HVAC - Sales Costco (NR)'
    '353'       = 'Plumbing - Service'
    '354'       = 'Plumbing - Maintenance'
    '408662213' = 'Plumbing - Install'
    '595105985' = 'Plumbing - Drains'
}

$TokenUrl = 'https://auth.servicetitan.io/connect/token'
$ApiBase  = 'https://api.servicetitan.io'

# --- Pacific time zone (Windows id "Pacific Standard Time" auto-handles PDT/PST) ---
try { $pac = [TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time') }
catch { Fail "Could not load the 'Pacific Standard Time' zone on this machine. $($_.Exception.Message)" }

function Parse-Utc([string]$s) {
    # Parse an ISO-8601 timestamp (with trailing Z) as a UTC DateTime.
    return [DateTime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture,
        ([Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal))
}

# --- Work out which Pacific day we're reporting on ---
if ([string]::IsNullOrWhiteSpace($Date)) {
    $pacNow   = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $pac)
    $selected = $pacNow.Date.AddDays(-1)          # yesterday, in Pacific
} else {
    try { $selected = [DateTime]::ParseExact($Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    catch { Fail "Date '$Date' is not valid. Use yyyy-MM-dd (e.g. 2026-07-15)." }
}

# Pacific midnight -> next Pacific midnight, expressed in UTC. This is the window.
$startLocal = [DateTime]::SpecifyKind($selected.Date, 'Unspecified')
$endLocal   = $startLocal.AddDays(1)
$startUtc   = [TimeZoneInfo]::ConvertTimeToUtc($startLocal, $pac)
$endUtc     = [TimeZoneInfo]::ConvertTimeToUtc($endLocal,   $pac)
$startIso   = $startUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
$endIso     = $endUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")

# --- Credentials (never printed) ---
$secretsPath = Join-Path $PSScriptRoot 'secrets.json'
if (-not (Test-Path $secretsPath)) { Fail "secrets.json not found next to this script." }
try { $secrets = Get-Content $secretsPath -Raw | ConvertFrom-Json } catch { Fail "secrets.json is not valid JSON: $($_.Exception.Message)" }
foreach ($f in 'clientId','clientSecret','appKey','tenantId') {
    if ([string]::IsNullOrWhiteSpace($secrets.$f)) { Fail "secrets.json is missing a value for '$f'." }
}
$tenant = $secrets.tenantId

# --- Access token ---
try {
    $tokenResp = Invoke-RestMethod -Method Post -Uri $TokenUrl -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type='client_credentials'; client_id=$secrets.clientId; client_secret=$secrets.clientSecret }
} catch {
    $st = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'n/a' }
    Fail "Token request failed (HTTP $st): $($_.Exception.Message)"
}
$token = $tokenResp.access_token
if ([string]::IsNullOrWhiteSpace($token)) { Fail "Auth server did not return an access token." }
$headers = @{ 'Authorization' = "Bearer $token"; 'ST-App-Key' = $secrets.appKey }

# --- Generic GET that pages through EVERYTHING (never trusts page 1) ---
function Get-AllPages($path, [hashtable]$params) {
    $all = New-Object System.Collections.ArrayList
    $page = 1
    $maxPages = 1000
    while ($true) {
        $pairs = @()
        foreach ($k in $params.Keys) { $pairs += ("{0}={1}" -f $k, [uri]::EscapeDataString([string]$params[$k])) }
        $pairs += "pageSize=200"
        $pairs += "page=$page"
        $url = "$ApiBase$path" + "?" + ($pairs -join '&')
        try {
            $resp = Invoke-RestMethod -Method Get -Uri $url -Headers $headers
        } catch {
            $st = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'n/a' }
            $body = ''
            if ($_.Exception.Response) {
                try { $body = (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch {}
            }
            Fail "API call failed (HTTP $st) on GET $path (page $page). $body"
        }
        if ($null -eq $resp.PSObject.Properties['data']) { Fail "Unexpected response from $path - no 'data' field." }
        if ($resp.data) { [void]$all.AddRange(@($resp.data)) }
        if (-not $resp.hasMore) { break }
        $page++
        if ($page -gt $maxPages) { Fail "Paging exceeded $maxPages pages on $path - aborting to avoid a runaway loop." }
    }
    return ,$all
}

# --- Build the job-type id -> name lookup (the filter matches on NAME) ---
$jobTypesList = Get-AllPages "/jpm/v2/tenant/$tenant/job-types" @{}
$jobTypeName = @{}
foreach ($jt in $jobTypesList) {
    if (($null -eq $jt.PSObject.Properties['id']) -or ($null -eq $jt.PSObject.Properties['name'])) {
        Fail "A job-types record is missing 'id' or 'name' - cannot build the job-type lookup."
    }
    $jobTypeName["$($jt.id)"] = $jt.name
}
if ($jobTypeName.Count -eq 0) { Fail "The job-types list came back empty - cannot apply the new-opportunity filter." }

# --- Pull the two job sets for this day ---
# NOTE (verified 2026-07-16): the jobs endpoint has NO working multi-BU filter. Plural
# `businessUnitIds` is silently IGNORED; singular `businessUnitId` takes ONE id only
# (comma-list 400s, repeated takes the first). So we fetch the day's completed jobs and
# filter to our reported units CLIENT-SIDE in the tally below - correctness never depends
# on a server-side BU filter.
$completedJobs = Get-AllPages "/jpm/v2/tenant/$tenant/jobs" @{
    completedOnOrAfter = $startIso
    completedBefore    = $endIso
    jobStatus          = 'Completed'
}
# BOOKED (scheduled-for-the-day) is computed further down, AFTER the filter helpers are
# defined, because it needs Is-Empty / Passes-Filter. It comes from APPOINTMENTS, not createdOn.
$appts = Get-AllPages "/jpm/v2/tenant/$tenant/appointments" @{
    startsOnOrAfter = $startIso
    startsBefore    = $endIso
}

# --- Helpers for the new-opportunity filter ---
function Is-Empty($v) {
    if ($null -eq $v) { return $true }
    if (($v -is [string]) -and ($v.Trim() -eq '')) { return $true }
    if (($v -is [int] -or $v -is [long] -or $v -is [double]) -and ($v -eq 0)) { return $true }
    return $false
}
function Passes-Filter($job) {
    foreach ($p in 'recallForId','warrantyId','jobTypeId','businessUnitId') {
        if ($null -eq $job.PSObject.Properties[$p]) {
            Fail "Job $($job.id) is missing field '$p' - cannot evaluate the new-opportunity filter safely."
        }
    }
    if (-not (Is-Empty $job.recallForId)) { return $false }   # it's a recall follow-up
    if (-not (Is-Empty $job.warrantyId))  { return $false }   # it's a warranty follow-up
    $btid = "$($job.jobTypeId)"
    if (-not $jobTypeName.ContainsKey($btid)) {
        Fail "Job $($job.id) has jobTypeId $btid, which is not in the job-types list - cannot resolve its name."
    }
    $name = $jobTypeName[$btid]
    if ([string]::IsNullOrWhiteSpace($name)) { Fail "Job type $btid resolved to an empty name - cannot apply the filter." }
    if ($name -match 'recall|warranty|part.*install') { return $false }   # -match is case-insensitive
    return $true
}

# --- Tally, re-verifying each job's Pacific day CLIENT-SIDE (defence vs a mis-read filter) ---
$booked = @{}; $completed = @{}
foreach ($id in $BUSINESS_UNITS.Keys) { $booked[$id] = 0; $completed[$id] = 0 }

# BOOKED = distinct qualifying jobs that have a NON-canceled appointment scheduled in the Pacific day.
#   1) collect distinct jobIds of appointments starting in the window (status != Canceled)
$schedJobIds = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($a in $appts) {
    if ($null -eq $a.PSObject.Properties['status']) { Fail "Appointment $($a.id) is missing status." }
    if ($a.status -eq 'Canceled') { continue }                     # canceled = cancel tray (M2), not on the board
    if ($null -eq $a.PSObject.Properties['start']) { Fail "Appointment $($a.id) is missing start." }
    $ts = Parse-Utc $a.start
    if (-not ($ts -ge $startUtc -and $ts -lt $endUtc)) { continue } # client-verify Pacific window
    if ($null -eq $a.PSObject.Properties['jobId']) { Fail "Appointment $($a.id) is missing jobId." }
    if (Is-Empty $a.jobId) { Fail "Appointment $($a.id) has an empty jobId." }
    [void]$schedJobIds.Add("$($a.jobId)")
}
#   2) batch-fetch those jobs by id; every requested id must come back or FAIL LOUD
$jobMap = @{}
$idList = @($schedJobIds)
$chunk  = 50
for ($i = 0; $i -lt $idList.Count; $i += $chunk) {
    $slice = $idList[$i..([Math]::Min($i + $chunk - 1, $idList.Count - 1))]
    $batch = Get-AllPages "/jpm/v2/tenant/$tenant/jobs" @{ ids = ($slice -join ',') }
    foreach ($j in $batch) { $jobMap["$($j.id)"] = $j }
}
$missing = @($idList | Where-Object { -not $jobMap.ContainsKey($_) })
if ($missing.Count -gt 0) { Fail "$($missing.Count) scheduled job id(s) could not be fetched (e.g. $($missing[0])) - cannot classify them." }
#   3) count distinct qualifying jobs per reported BU
foreach ($jid in $idList) {
    $job = $jobMap[$jid]
    if ($null -eq $job.PSObject.Properties['businessUnitId']) { Fail "Job $jid is missing businessUnitId." }
    $bu = "$($job.businessUnitId)"
    if (-not $BUSINESS_UNITS.Contains($bu)) { continue }            # not a reported unit (e.g. Inventory) - ignore
    if (Passes-Filter $job) { $booked[$bu]++ }
}

foreach ($job in $completedJobs) {
    $bu = "$($job.businessUnitId)"
    if (-not $BUSINESS_UNITS.Contains($bu)) { continue }
    if ($null -eq $job.PSObject.Properties['jobStatus']) { Fail "Job $($job.id) is missing jobStatus." }
    if ($job.jobStatus -ne 'Completed') { continue }              # defensive: only truly-completed
    if ($null -eq $job.PSObject.Properties['completedOn']) { Fail "Job $($job.id) is missing completedOn." }
    if ([string]::IsNullOrWhiteSpace([string]$job.completedOn)) { Fail "Completed job $($job.id) has an empty completedOn." }
    $t = Parse-Utc $job.completedOn
    if ($t -ge $startUtc -and $t -lt $endUtc) {
        if (Passes-Filter $job) { $completed[$bu]++ }
    }
}

# --- Output ---
Write-Host ""
Write-Host "CALL COUNT - new opportunities" -ForegroundColor Cyan
Write-Host "Pacific day : $($selected.ToString('yyyy-MM-dd')) (America/Los_Angeles)"
Write-Host "UTC window  : $startIso  ..  $endIso"
Write-Host "Scanned: appointments $($appts.Count) (booked=scheduled that day), completed-jobs $($completedJobs.Count)"
Write-Host ""

$rows = foreach ($id in $BUSINESS_UNITS.Keys) {
    [PSCustomObject]@{
        'Business Unit' = $BUSINESS_UNITS[$id]
        'Booked'        = $booked[$id]
        'Completed'     = $completed[$id]
    }
}
$rows | Format-Table -AutoSize | Out-String | Write-Host

$tb = ($booked.Values   | Measure-Object -Sum).Sum
$tc = ($completed.Values | Measure-Object -Sum).Sum
if ($null -eq $tb) { $tb = 0 }
if ($null -eq $tc) { $tc = 0 }
Write-Host ("TOTAL 9 units, Inventory excluded    Booked: {0}    Completed: {1}" -f $tb, $tc) -ForegroundColor Green
Write-Host ""
Write-Host "Booked = calls SCHEDULED FOR this day (on the board). Completed = calls finished this day." -ForegroundColor DarkGray
Write-Host "They count different jobs (scheduled one day, completed another), so they are not expected to match." -ForegroundColor DarkGray
Write-Host ""
