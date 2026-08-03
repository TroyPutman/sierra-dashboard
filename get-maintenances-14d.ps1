# ============================================================================
#  get-maintenances-14d.ps1  (M5 - built 2026-07-16)
#  MAINTENANCES BOOKED ON THE CALENDAR over the next 14 days. Prints to screen.
#  Purpose: see the dead space to fill.
#
#  Follows SPEC.md (M5), per Troy's 2026-07-16 decision:
#    - Count what's actually BOOKED ON THE CALENDAR = maintenance APPOINTMENTS (visits)
#      scheduled in the next 14 days from TODAY. NOT membership obligations.
#    - Window anchored from today (Pacific). Count visits (appointments), status != Canceled.
#    - Broken out by day (dead space shows as low daily counts) and by trade (HVAC / Plumbing).
#    - Pages through EVERY page. Fails loud on API error / missing field.
#
#  "Maintenance" job types are defined by the editable $MAINT_PATTERNS list below. The script
#  PRINTS exactly which job types matched (with counts) so the definition is transparent - this
#  set is PROVISIONAL until Troy confirms it. NOT marked verified.
#
#  Usage:  .\get-maintenances-14d.ps1        (always from today; no date param)
# ============================================================================

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Fail($msg) { Write-Host ""; Write-Host "FAILED: $msg" -ForegroundColor Red; Write-Host ""; exit 1 }

# ---- Maintenance SECTIONS (ordered; a job type falls into the FIRST matching section). Edit / confirm w/ Troy. ----
$SECTIONS = @(
    @{ Name = 'SAM Cooling (HVAC cooling maint)';        Patterns = @('^SAM Cooling Service') },
    @{ Name = 'SAM Heating (HVAC heating maint)';        Patterns = @('^SAM Heating Service') },
    @{ Name = 'HVAC Semi-Annual Tune-ups';               Patterns = @('^Semi Annual Tune-up') },
    @{ Name = 'Filter Changes';                          Patterns = @('^Filter Change') },
    @{ Name = 'Plumbing Water Heater Maintenance (SAM)'; Patterns = @('^Plumbing SAM .*Water Heater Service') },
    @{ Name = 'Plumbing Water Heater Tune-ups';          Patterns = @('Water Heater Tune-up') },
    @{ Name = 'Commercial Maintenance';                  Patterns = @('^Commercial Cooling/Heating Maintenance') }
)
$SECTION_ORDER = $SECTIONS | ForEach-Object { $_.Name }

# trade mapping (business unit id -> trade)
$HVAC_BUS = @('333','337','342817560','370','340802904')
$PLMB_BUS = @('595105985','408662213','354','353')

$TokenUrl = 'https://auth.servicetitan.io/connect/token'
$ApiBase  = 'https://api.servicetitan.io'

try { $pac = [TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time') }
catch { Fail "Could not load the 'Pacific Standard Time' zone. $($_.Exception.Message)" }

function Parse-Utc([string]$s) {
    return [DateTime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture,
        ([Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal))
}
function Is-Empty($v) {
    if ($null -eq $v) { return $true }
    if (($v -is [string]) -and ($v.Trim() -eq '')) { return $true }
    if (($v -is [int] -or $v -is [long] -or $v -is [double]) -and ($v -eq 0)) { return $true }
    return $false
}

# window: today (Pacific) 00:00 -> +14 days
$today   = ([TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $pac)).Date
$endDay  = $today.AddDays(14)
$startUtc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($today, 'Unspecified'), $pac)
$endUtc   = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($endDay, 'Unspecified'), $pac)
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
    $page = 1; $maxPages = 2000
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

# job-type id -> name
$jobTypeName = @{}
foreach ($jt in (Get-AllPages "/jpm/v2/tenant/$tenant/job-types" @{})) {
    if (($null -eq $jt.PSObject.Properties['id']) -or ($null -eq $jt.PSObject.Properties['name'])) { Fail "A job-types record is missing id or name." }
    $jobTypeName["$($jt.id)"] = $jt.name
}
function Get-Section([string]$name) {
    foreach ($sec in $SECTIONS) { foreach ($p in $sec.Patterns) { if ($name -match $p) { return $sec.Name } } }
    return $null
}

# appointments scheduled in the window
$appts = Get-AllPages "/jpm/v2/tenant/$tenant/appointments" @{ startsOnOrAfter=$startIso; startsBefore=$endIso }
$byJob = @{}   # jobId -> list of appointment start (Pacific date string)
foreach ($a in $appts) {
    if ($null -eq $a.PSObject.Properties['status']) { Fail "Appointment $($a.id) is missing status." }
    if ($a.status -eq 'Canceled') { continue }
    if ($null -eq $a.PSObject.Properties['start']) { Fail "Appointment $($a.id) is missing start." }
    $ts = Parse-Utc $a.start
    if (-not ($ts -ge $startUtc -and $ts -lt $endUtc)) { continue }
    if ($null -eq $a.PSObject.Properties['jobId']) { Fail "Appointment $($a.id) is missing jobId." }
    if (Is-Empty $a.jobId) { continue }
    $jid = "$($a.jobId)"
    $pd = ([TimeZoneInfo]::ConvertTimeFromUtc($ts, $pac)).ToString('yyyy-MM-dd')
    if (-not $byJob.ContainsKey($jid)) { $byJob[$jid] = New-Object System.Collections.ArrayList }
    [void]$byJob[$jid].Add($pd)
}

# fetch those jobs (jobTypeId + businessUnitId)
$jobMap = @{}
$idList = @($byJob.Keys); $chunk = 50
for ($i = 0; $i -lt $idList.Count; $i += $chunk) {
    $slice = $idList[$i..([Math]::Min($i + $chunk - 1, $idList.Count - 1))]
    foreach ($j in (Get-AllPages "/jpm/v2/tenant/$tenant/jobs" @{ ids = ($slice -join ',') })) { $jobMap["$($j.id)"] = $j }
}
$missing = @($idList | Where-Object { -not $jobMap.ContainsKey($_) })
if ($missing.Count -gt 0) { Fail "$($missing.Count) scheduled job id(s) could not be fetched (e.g. $($missing[0]))." }

# tally maintenance visits by day x trade
$dayStrs = 0..13 | ForEach-Object { $today.AddDays($_).ToString('yyyy-MM-dd') }
$countHV = @{}; $countPL = @{}; $countOT = @{}
foreach ($ds in $dayStrs) { $countHV[$ds] = 0; $countPL[$ds] = 0; $countOT[$ds] = 0 }
$secCount = @{}; $secTypes = @{}
foreach ($n in $SECTION_ORDER) { $secCount[$n] = 0; $secTypes[$n] = @{} }

foreach ($jid in $idList) {
    $job = $jobMap[$jid]
    if ($null -eq $job.PSObject.Properties['jobTypeId']) { Fail "Job $jid is missing jobTypeId." }
    $tid = "$($job.jobTypeId)"
    if (-not $jobTypeName.ContainsKey($tid)) { Fail "Job $jid has jobTypeId $tid not in the job-types list." }
    $name = $jobTypeName[$tid]
    $section = Get-Section $name
    if (-not $section) { continue }
    if ($null -eq $job.PSObject.Properties['businessUnitId']) { Fail "Job $jid is missing businessUnitId." }
    $bu = "$($job.businessUnitId)"
    foreach ($pd in $byJob[$jid]) {
        if (-not $countHV.ContainsKey($pd)) { continue }   # safety: only our 14 days
        $secCount[$section]++                              # count VISITS (one per appointment day)
        $secTypes[$section][$name] = 1 + ($(if ($secTypes[$section].ContainsKey($name)) { $secTypes[$section][$name] } else { 0 }))
        if     ($HVAC_BUS -contains $bu) { $countHV[$pd]++ }
        elseif ($PLMB_BUS -contains $bu) { $countPL[$pd]++ }
        else                             { $countOT[$pd]++ }
    }
}

# ---- output ----
Write-Host ""
Write-Host "MAINTENANCES BOOKED - next 14 days (from today)" -ForegroundColor Cyan
Write-Host "Window (Pacific): $($today.ToString('yyyy-MM-dd')) .. $($endDay.AddDays(-1).ToString('yyyy-MM-dd'))"
Write-Host "Appointments scanned: $($appts.Count)"
Write-Host ""

Write-Host "BY SECTION (14-day visit totals):" -ForegroundColor Cyan
$secRows = foreach ($n in $SECTION_ORDER) { [PSCustomObject]@{ 'Section' = $n; 'Visits' = $secCount[$n] } }
$secRows | Format-Table -AutoSize | Out-String | Write-Host
$grand = ($secRows | Measure-Object -Property Visits -Sum).Sum
Write-Host ("GRAND TOTAL (all sections): {0}" -f $grand) -ForegroundColor Green
Write-Host ""

Write-Host "BY DAY (dead space to fill):" -ForegroundColor Cyan
$rows = foreach ($ds in $dayStrs) {
    [PSCustomObject]@{
        'Date'     = $ds
        'HVAC'     = $countHV[$ds]
        'Plumbing' = $countPL[$ds]
        'Other'    = $countOT[$ds]
        'Total'    = $countHV[$ds] + $countPL[$ds] + $countOT[$ds]
    }
}
$rows | Format-Table -AutoSize | Out-String | Write-Host

Write-Host "Matched job types per section (transparency - CONFIRM WITH TROY which sections count):" -ForegroundColor Yellow
foreach ($n in $SECTION_ORDER) {
    Write-Host ("  [{0}]  total {1}" -f $n, $secCount[$n]) -ForegroundColor Cyan
    if ($secTypes[$n].Count -eq 0) { Write-Host "     (none scheduled in window)" -ForegroundColor DarkGray }
    else { $secTypes[$n].GetEnumerator() | Sort-Object Name | ForEach-Object { Write-Host ("     {0,-48} {1}" -f $_.Key, $_.Value) -ForegroundColor DarkGray } }
}
Write-Host ""
Write-Host "NOTE: sections/job-type set are PROVISIONAL (defined at top of script). 'Other' = matched-maintenance" -ForegroundColor Yellow
Write-Host "jobs whose business unit is neither HVAC nor Plumbing trade (e.g. commercial)." -ForegroundColor Yellow
Write-Host ""
