# ============================================================================
#  get-calls-per-tech.ps1
#  Metric M3: CALLS PER TECH per business unit, for ONE Pacific day.
#  Prints numbers to screen. No dashboard.
#
#  Follows SPEC.md (M3):
#    - Numerator   = completed "calls" (new-opportunity jobs) in the unit that day
#                    (exactly M1's completed set - same new-opportunity filter).
#    - Denominator = distinct technicians who ran >=1 of those jobs (from active
#                    appointment-assignments).
#    - Calls per tech = numerator / denominator, 1 decimal. If denominator = 0,
#      shows "-" (never 0, never a divide error).
#    - ONLY HVAC-Service (333) and Plumbing-Service (353). Two rows. (Troy 2026-07-16.)
#    - Pages through EVERY page - never trusts page 1.
#    - Single day only. MTD/YTD deliberately NOT built (SPEC OQ #3: the period
#      denominator is still undecided).
#
#  Fails loud: any API error / missing field -> STOP and say what went wrong.
#
#  Usage:
#    .\get-calls-per-tech.ps1                 # defaults to yesterday (Pacific)
#    .\get-calls-per-tech.ps1 -Date 2026-07-15
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

# --- SCOPE (SPEC.md M3, Troy 2026-07-16): ONLY the two Service units. Two rows. ---
#     Not installers/sales/maintenance/drains. Numerator AND tech denominator are
#     restricted to these units.
$BUSINESS_UNITS = [ordered]@{
    '333' = 'HVAC - Service'
    '353' = 'Plumbing - Service'
}

$TokenUrl = 'https://auth.servicetitan.io/connect/token'
$ApiBase  = 'https://api.servicetitan.io'

# --- Pacific time zone ---
try { $pac = [TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time') }
catch { Fail "Could not load the 'Pacific Standard Time' zone on this machine. $($_.Exception.Message)" }

function Parse-Utc([string]$s) {
    return [DateTime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture,
        ([Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal))
}

# --- Which Pacific day ---
if ([string]::IsNullOrWhiteSpace($Date)) {
    $pacNow   = [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $pac)
    $selected = $pacNow.Date.AddDays(-1)
} else {
    try { $selected = [DateTime]::ParseExact($Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    catch { Fail "Date '$Date' is not valid. Use yyyy-MM-dd (e.g. 2026-07-15)." }
}

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

# --- Job-type id -> name lookup (jpm namespace), for the new-opportunity filter ---
$jobTypesList = Get-AllPages "/jpm/v2/tenant/$tenant/job-types" @{}
$jobTypeName = @{}
foreach ($jt in $jobTypesList) {
    if (($null -eq $jt.PSObject.Properties['id']) -or ($null -eq $jt.PSObject.Properties['name'])) {
        Fail "A job-types record is missing 'id' or 'name' - cannot build the job-type lookup."
    }
    $jobTypeName["$($jt.id)"] = $jt.name
}
if ($jobTypeName.Count -eq 0) { Fail "The job-types list came back empty - cannot apply the new-opportunity filter." }

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
    if (-not (Is-Empty $job.recallForId)) { return $false }
    if (-not (Is-Empty $job.warrantyId))  { return $false }
    $btid = "$($job.jobTypeId)"
    if (-not $jobTypeName.ContainsKey($btid)) {
        Fail "Job $($job.id) has jobTypeId $btid, which is not in the job-types list - cannot resolve its name."
    }
    $name = $jobTypeName[$btid]
    if ([string]::IsNullOrWhiteSpace($name)) { Fail "Job type $btid resolved to an empty name - cannot apply the filter." }
    if ($name -match 'recall|warranty|part.*install') { return $false }
    return $true
}

# --- Get the day's qualifying completed jobs (exactly as M1) ---
# NOTE (verified 2026-07-16): jobs endpoint has NO working multi-BU filter (plural
# `businessUnitIds` ignored; singular `businessUnitId` is single-value only). We fetch the
# day's completed jobs and filter to the two Service units client-side in the tally below.
$completedJobs = Get-AllPages "/jpm/v2/tenant/$tenant/jobs" @{
    completedOnOrAfter = $startIso
    completedBefore    = $endIso
    jobStatus          = 'Completed'
}

# Keep only qualifying jobs really completed in the Pacific window, per BU.
$jobsByBu = @{}
foreach ($id in $BUSINESS_UNITS.Keys) { $jobsByBu[$id] = New-Object System.Collections.ArrayList }
foreach ($job in $completedJobs) {
    $bu = "$($job.businessUnitId)"
    if (-not $BUSINESS_UNITS.Contains($bu)) { continue }
    if ($job.jobStatus -ne 'Completed') { continue }
    if ($null -eq $job.PSObject.Properties['completedOn']) { Fail "Job $($job.id) is missing completedOn." }
    if ([string]::IsNullOrWhiteSpace([string]$job.completedOn)) { Fail "Completed job $($job.id) has an empty completedOn." }
    $t = Parse-Utc $job.completedOn
    if ($t -ge $startUtc -and $t -lt $endUtc) {
        if (Passes-Filter $job) { [void]$jobsByBu[$bu].Add($job) }
    }
}

# --- For each qualifying completed job, pull its ACTIVE tech assignments ---
$techByBu = @{}   # BU -> HashSet of technicianId
foreach ($id in $BUSINESS_UNITS.Keys) { $techByBu[$id] = New-Object 'System.Collections.Generic.HashSet[string]' }
$unattributed = 0   # completed jobs with no active tech assignment

foreach ($id in $BUSINESS_UNITS.Keys) {
    foreach ($job in $jobsByBu[$id]) {
        $assigns = Get-AllPages "/dispatch/v2/tenant/$tenant/appointment-assignments" @{ jobId = "$($job.id)" }
        $foundTech = $false
        foreach ($a in $assigns) {
            if ($null -eq $a.PSObject.Properties['active']) { Fail "Assignment for job $($job.id) is missing 'active'." }
            if (-not $a.active) { continue }                       # only active assignments
            if ($null -eq $a.PSObject.Properties['technicianId']) { Fail "Active assignment for job $($job.id) is missing 'technicianId'." }
            if (Is-Empty $a.technicianId) { continue }
            [void]$techByBu[$id].Add("$($a.technicianId)")
            $foundTech = $true
        }
        if (-not $foundTech) { $unattributed++ }
    }
}

# --- Output ---
Write-Host ""
Write-Host "CALLS PER TECH - new opportunities completed" -ForegroundColor Cyan
Write-Host "Pacific day : $($selected.ToString('yyyy-MM-dd')) (America/Los_Angeles)"
Write-Host "UTC window  : $startIso  ..  $endIso"
Write-Host "Completed-jobs scanned: $($completedJobs.Count)"
Write-Host ""

$allTechs = New-Object 'System.Collections.Generic.HashSet[string]'
$rows = foreach ($id in $BUSINESS_UNITS.Keys) {
    $numer = $jobsByBu[$id].Count
    $denom = $techByBu[$id].Count
    foreach ($tid in $techByBu[$id]) { [void]$allTechs.Add($tid) }
    $ratio = if ($denom -gt 0) { "{0:N1}" -f ($numer / $denom) } else { "-" }
    [PSCustomObject]@{
        'Business Unit'   = $BUSINESS_UNITS[$id]
        'Completed Calls' = $numer
        'Techs'           = $denom
        'Calls/Tech'      = $ratio
    }
}
$rows | Format-Table -AutoSize | Out-String | Write-Host

$totalCalls = 0; foreach ($id in $BUSINESS_UNITS.Keys) { $totalCalls += $jobsByBu[$id].Count }
$totalTechs = $allTechs.Count
$overall = if ($totalTechs -gt 0) { "{0:N1}" -f ($totalCalls / $totalTechs) } else { "-" }
Write-Host ("TOTAL (2 Service units)    Completed Calls: {0}    Distinct Techs: {1}    Overall Calls/Tech: {2}" -f $totalCalls, $totalTechs, $overall) -ForegroundColor Green
Write-Host ""
if ($unattributed -gt 0) {
    Write-Host ("NOTE: $unattributed completed call(s) had no active tech assignment - counted in Completed Calls") -ForegroundColor Yellow
    Write-Host ("but contributing no technician to the denominator.") -ForegroundColor Yellow
}
Write-Host "SCOPE: HVAC-Service (333) + Plumbing-Service (353) only, per Troy. CAVEAT (SPEC OQ #3): within these" -ForegroundColor Yellow
Write-Host "units, 'Techs' = distinct technicianId on active assignments, which may still include helpers/ride-alongs;" -ForegroundColor Yellow
Write-Host "if inflated, next lever is counting only the primary assignment per job. MTD/YTD not built (period" -ForegroundColor Yellow
Write-Host "denominator undecided). Single-day only." -ForegroundColor Yellow
Write-Host ""
