# ============================================================================
#  probe-overtime-lag.ps1  (diagnostic probe, built 2026-07-29 - NOT a metric script)
#  Re-run this in a few days with ZERO arguments. It auto-compares against its own
#  most recent earlier run and tells you, in plain English, what changed.
#
#  WHY THIS EXISTS (condensed):
#  We are testing two hypotheses about why M4 Overtime shows 0 on Fridays/Saturdays,
#  and why the two most recent days in the payroll feed look suspiciously low:
#    H1 (Friday payroll-week start): Sierra's payroll workweek appears to start on
#       Friday, so nobody has crossed the weekly 40-hour OT threshold yet by Fri/Sat.
#       If TRUE, Fri/Sat OT stays 0 FOREVER - re-pulling later never changes it.
#    H2 (payroll feed lag): the feed is incomplete for the most recent 1-2 days.
#       On the 2026-07-29 baseline pull, 2026-07-27 had 1,256 total pay items and
#       2026-07-28 had 1,004 - roughly HALF of comparable Mondays (~2,150) and
#       Tuesdays (~1,976). If TRUE, those two days will FILL IN (climb toward
#       ~2,000) on a later re-pull. This matters because M4 reports YESTERDAY,
#       which may be the least-complete day in the feed at the time it's shown.
#  Re-running this script re-pulls the SAME fixed date window and diffs the new
#  per-day numbers against the prior run: Fridays/Saturdays should stay 0 (confirms
#  H1); 07-27 and 07-28 should climb toward ~2,000 (confirms H2).
#
#  Auth/paging copied from get-overtime.ps1: secrets.json beside this script
#  (clientId, clientSecret, appKey, tenantId); token POST to
#  https://auth.servicetitan.io/connect/token; headers Authorization Bearer +
#  ST-App-Key; base https://api.servicetitan.io; pageSize=2500, follow hasMore.
#  (2026-08-03: pageSize=300 was found to return byte-identical duplicate rows across
#  page boundaries on this endpoint, inflating OT totals ~28-39%. 2500 keeps a work day
#  in one page and returns zero dupes. Do not lower it.)
#
#  Endpoint: /payroll/v2/tenant/<tenant>/gross-pay-items
#  KNOWN API QUIRK (already verified): startedOnOrAfter is IGNORED by this endpoint
#  and returns ~2M rows. Do NOT use it. dateOnOrAfter/dateOnOrBefore (on the `date`
#  field) is the working filter, and that is what this script uses.
#
#  Output: writes one JSON file per run to .\ot-probe\run-YYYY-MM-DD-HHmm.json
#  (a folder OUTSIDE of data\, so it can never be mistaken for or collide with
#  serve.ps1's data\<date>.json snapshot cache - serve.ps1 only ever looks at
#  data\<yyyy-MM-dd>.json and data\silo-<yyyy-MM>.json, both different names/folder).
#
#  Usage:  .\probe-overtime-lag.ps1        (no arguments, ever)
# ============================================================================

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Fail($msg) { Write-Host ""; Write-Host "FAILED: $msg" -ForegroundColor Red; Write-Host ""; exit 1 }

Write-Host ""
Write-Host "=== OVERTIME LAG PROBE ===" -ForegroundColor Cyan
Write-Host "Purpose: test whether Fri/Sat OT=0 is a real payroll-week-start effect (H1, should" -ForegroundColor Cyan
Write-Host "stay 0 forever) and whether 07-27/07-28's low pay-item counts are payroll feed LAG" -ForegroundColor Cyan
Write-Host "(H2, should climb toward ~2,000 on a later re-pull). See header comment for detail." -ForegroundColor Cyan
Write-Host ""

# --- FIXED pull window: must NEVER change, or past runs stop being comparable ---
$WINDOW_AFTER  = '2026-07-08T00:00:00Z'
$WINDOW_BEFORE = '2026-07-28T23:59:59Z'
$WINDOW_START_DATE = [DateTime]::ParseExact('2026-07-08','yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
$WINDOW_END_DATE   = [DateTime]::ParseExact('2026-07-28','yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)

$SERVICE_UNITS = @('HVAC - Service', 'Plumbing - Service')

$TokenUrl = 'https://auth.servicetitan.io/connect/token'
$ApiBase  = 'https://api.servicetitan.io'

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
        # pageSize MUST stay large enough that a work day fits in ONE page. This endpoint returns
        # exact DUPLICATE rows across page boundaries at pageSize=300 (inflates OT totals by
        # ~28-39%, varies run to run). pageSize=200 and 2500 both return zero dupes; 2500 keeps a
        # day single-page. API cap is 5000. Do not lower this.
        $pairs += "pageSize=2500"; $pairs += "page=$page"
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

$sw = [Diagnostics.Stopwatch]::StartNew()
$items = Get-AllPages "/payroll/v2/tenant/$tenant/gross-pay-items" @{ dateOnOrAfter = $WINDOW_AFTER; dateOnOrBefore = $WINDOW_BEFORE }
$sw.Stop()

if ($null -eq $items -or $items.Count -eq 0) { Fail "Pull returned ZERO rows for the fixed window $WINDOW_AFTER .. $WINDOW_BEFORE - this is almost certainly an API problem, not a real empty payroll feed. Refusing to report a 0." }

# --- build the full 21-day scaffold, every date present even if 0 ---
$dayMap = @{}
$d = $WINDOW_START_DATE
while ($d -le $WINDOW_END_DATE) {
    $ds = $d.ToString('yyyy-MM-dd')
    $dayMap[$ds] = [PSCustomObject]@{
        Date                = $ds
        DayOfWeek           = $d.DayOfWeek.ToString()
        TotalPayItems       = 0
        OTItemCount         = 0
        OTHours_AllUnits    = 0.0
        OTHours_ServiceOnly = 0.0
    }
    $d = $d.AddDays(1)
}

foreach ($it in $items) {
    if ($null -eq $it.PSObject.Properties['date']) { Fail "A gross-pay-item ($($it.id)) is missing the 'date' field." }
    $pd = [DateTime]::Parse($it.date, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
    $ds = $pd.ToString('yyyy-MM-dd')
    if (-not $dayMap.ContainsKey($ds)) { continue }   # outside our 21-day window (shouldn't happen given the filter, but be safe)
    $row = $dayMap[$ds]
    $row.TotalPayItems++

    if ($null -eq $it.PSObject.Properties['paidTimeType']) { Fail "Gross-pay-item $($it.id) is missing paidTimeType." }
    if ($it.paidTimeType -ne 'Overtime') { continue }
    $row.OTItemCount++

    if ($null -eq $it.PSObject.Properties['paidDurationHours']) { Fail "Overtime item $($it.id) is missing paidDurationHours." }
    $hrs = 0.0
    if (-not [double]::TryParse("$($it.paidDurationHours)", [ref]$hrs)) { Fail "Overtime item $($it.id) has non-numeric paidDurationHours '$($it.paidDurationHours)'." }
    $row.OTHours_AllUnits += $hrs

    if ($null -ne $it.PSObject.Properties['payoutBusinessUnitName'] -and ($SERVICE_UNITS -contains "$($it.payoutBusinessUnitName)")) {
        $row.OTHours_ServiceOnly += $hrs
    }
}

$perDay = $dayMap.Keys | Sort-Object | ForEach-Object {
    $r = $dayMap[$_]
    [PSCustomObject]@{
        Date                = $r.Date
        DayOfWeek           = $r.DayOfWeek
        TotalPayItems       = $r.TotalPayItems
        OTItemCount         = $r.OTItemCount
        OTHours_AllUnits    = [math]::Round($r.OTHours_AllUnits, 1)
        OTHours_ServiceOnly = [math]::Round($r.OTHours_ServiceOnly, 1)
    }
}

# --- print the per-day table ---
Write-Host "Total rows pulled : $($items.Count)"
Write-Host ("Pull duration     : {0:N1} sec" -f $sw.Elapsed.TotalSeconds)
Write-Host ""
Write-Host "PER-DAY TABLE (window $($WINDOW_START_DATE.ToString('yyyy-MM-dd')) .. $($WINDOW_END_DATE.ToString('yyyy-MM-dd'))):" -ForegroundColor Cyan
$perDay | Format-Table -AutoSize | Out-String | Write-Host

# --- save this run ---
$probeDir = Join-Path $PSScriptRoot 'ot-probe'
if (-not (Test-Path $probeDir)) { New-Item -ItemType Directory -Path $probeDir | Out-Null }
$runTime = Get-Date
$runStamp = $runTime.ToString('yyyy-MM-dd-HHmm')
$runFile = Join-Path $probeDir "run-$runStamp.json"

$runRecord = [PSCustomObject]@{
    runTimestamp   = $runTime.ToString('o')
    windowAfter    = $WINDOW_AFTER
    windowBefore   = $WINDOW_BEFORE
    totalRowsPulled= $items.Count
    pullSeconds    = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    perDay         = $perDay
}
$runRecord | ConvertTo-Json -Depth 6 | Set-Content -Path $runFile -Encoding UTF8
Write-Host "Saved this run to: $runFile" -ForegroundColor DarkGray
Write-Host ""

# --- find the most recent PRIOR run (exclude the one we just wrote) ---
$priorFiles = Get-ChildItem -Path $probeDir -Filter 'run-*.json' -File |
    Where-Object { $_.FullName -ne (Resolve-Path $runFile).Path } |
    Sort-Object Name -Descending
$priorFile = $priorFiles | Select-Object -First 1

if (-not $priorFile) {
    Write-Host "BASELINE RUN - no earlier run to compare against yet. Re-run in 3-4 days." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "WHAT TO LOOK FOR NEXT TIME:" -ForegroundColor Yellow
    Write-Host " - Fridays (07-10, 07-17, 07-24) and Saturdays (07-11, 07-18, 07-25) should STILL show" -ForegroundColor Yellow
    Write-Host "   OTItemCount = 0. If any of those become non-zero, the Friday-payroll-week theory is wrong." -ForegroundColor Yellow
    Write-Host " - 2026-07-27 and 2026-07-28's TotalPayItems (currently $($dayMap['2026-07-27'].TotalPayItems) and" -ForegroundColor Yellow
    Write-Host "   $($dayMap['2026-07-28'].TotalPayItems)) should climb toward ~2,000 if the payroll feed is lagging." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# --- load prior run and build the comparison table ---
try { $prior = Get-Content $priorFile.FullName -Raw | ConvertFrom-Json } catch { Fail "Could not read prior run file $($priorFile.FullName): $($_.Exception.Message)" }
$priorByDate = @{}
foreach ($p in $prior.perDay) { $priorByDate[$p.Date] = $p }

Write-Host ("COMPARISON vs prior run: {0}  (file: {1})" -f $prior.runTimestamp, $priorFile.Name) -ForegroundColor Cyan
$cmpRows = foreach ($cur in $perDay) {
    $prevRow = $priorByDate[$cur.Date]
    if ($null -eq $prevRow) {
        [PSCustomObject]@{
            Date = $cur.Date; DayOfWeek = $cur.DayOfWeek
            TotalItems_Then = 'n/a'; TotalItems_Now = $cur.TotalPayItems; Change_Total = 'n/a'
            OT_Then = 'n/a'; OT_Now = $cur.OTItemCount; Change_OT = 'n/a'
        }
    } else {
        [PSCustomObject]@{
            Date = $cur.Date; DayOfWeek = $cur.DayOfWeek
            TotalItems_Then = $prevRow.TotalPayItems; TotalItems_Now = $cur.TotalPayItems
            Change_Total = ($cur.TotalPayItems - $prevRow.TotalPayItems)
            OT_Then = $prevRow.OTItemCount; OT_Now = $cur.OTItemCount
            Change_OT = ($cur.OTItemCount - $prevRow.OTItemCount)
        }
    }
}
$cmpRows | Format-Table -AutoSize | Out-String | Write-Host

# --- plain-English verdict ---
Write-Host "VERDICT:" -ForegroundColor Green
Write-Host ""

# H1: Fri/Sat should stay 0
$fridaysSaturdays = $perDay | Where-Object { $_.DayOfWeek -eq 'Friday' -or $_.DayOfWeek -eq 'Saturday' }
$nonZeroFriSat = $fridaysSaturdays | Where-Object { $_.OTItemCount -ne 0 }
if ($nonZeroFriSat.Count -eq 0) {
    Write-Host "H1 (Friday payroll-week start): STILL HOLDS. Every Friday and Saturday in the window" -ForegroundColor Green
    Write-Host "still shows 0 overtime items. This supports the theory that the payroll week starts on" -ForegroundColor Green
    Write-Host "Friday, so nobody has crossed 40 hours yet by Fri/Sat - these zeros are real and correct." -ForegroundColor Green
} else {
    Write-Host "H1 (Friday payroll-week start): DISPROVEN. The following Friday/Saturday dates now show" -ForegroundColor Red
    Write-Host "NON-ZERO overtime, which should never happen if the payroll week truly starts Friday:" -ForegroundColor Red
    ($nonZeroFriSat | Select-Object Date, DayOfWeek, OTItemCount) | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "The Friday-start-workweek theory needs rethinking." -ForegroundColor Red
}
Write-Host ""

# H2: 07-27/07-28 should climb toward ~2000
$d27 = $priorByDate['2026-07-27']; $d28 = $priorByDate['2026-07-28']
$cur27 = $dayMap['2026-07-27'].TotalPayItems; $cur28 = $dayMap['2026-07-28'].TotalPayItems
if ($d27 -and $d28) {
    $delta27 = $cur27 - $d27.TotalPayItems
    $delta28 = $cur28 - $d28.TotalPayItems
    $materialRise = ($delta27 -ge 300) -or ($delta28 -ge 300)   # meaningfully closer to ~2000, not noise
    if ($materialRise) {
        Write-Host ("H2 (payroll feed lag): CONFIRMED. 2026-07-27 went from {0} to {1} pay items (change {2}), and" -f $d27.TotalPayItems, $cur27, $delta27) -ForegroundColor Green
        Write-Host ("2026-07-28 went from {0} to {1} (change {2}). Both rose materially toward the ~2,000 level seen" -f $d28.TotalPayItems, $cur28, $delta28) -ForegroundColor Green
        Write-Host "on comparable weekdays. This means the payroll feed DOES lag, and M4's 'yesterday' number is" -ForegroundColor Green
        Write-Host "SYSTEMATICALLY INCOMPLETE the first time it's shown - it should be treated as provisional." -ForegroundColor Green
    } else {
        Write-Host ("H2 (payroll feed lag): NOT CONFIRMED. 2026-07-27 went from {0} to {1} (change {2}), and" -f $d27.TotalPayItems, $cur27, $delta27) -ForegroundColor Yellow
        Write-Host ("2026-07-28 went from {0} to {1} (change {2}). Neither moved materially toward ~2,000, so the" -f $d28.TotalPayItems, $cur28, $delta28) -ForegroundColor Yellow
        Write-Host "low counts on those two days do NOT look like feed lag - something else explains them (real low" -ForegroundColor Yellow
        Write-Host "activity, a permanent gap, etc.) and is worth asking ServiceTitan about directly." -ForegroundColor Yellow
    }
} else {
    Write-Host "H2: Could not compare 2026-07-27/07-28 against the prior run (prior run is missing one of those dates)." -ForegroundColor Yellow
}
Write-Host ""
