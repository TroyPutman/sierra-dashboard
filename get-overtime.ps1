# ============================================================================
#  get-overtime.ps1  (M4 - built 2026-07-16)
#  OVERTIME hours for the DAY BEFORE, for Service techs only. Prints to screen.
#
#  Follows SPEC.md (M4), per Troy's 2026-07-16 decisions:
#    - The day before ONLY (default = yesterday). Payroll lag is fine (we look back).
#    - ONLY HVAC-Service and Plumbing-Service techs, two rows. Grouped by the tech's
#      home/payout unit (payoutBusinessUnitName), since overtime is the person's, not a job's.
#    - Overtime = gross-pay-items with paidTimeType = 'Overtime' (confirmed live 2026-07-16;
#      no separate DoubleTime value exists in the data - Troy's double-time question is moot for now).
#    - Work day is the `date` field (a calendar date stored at UTC midnight), filtered with
#      dateOnOrAfter/dateOnOrBefore. NB: this is NOT the Pacific-07:00 window used by other
#      metrics - payroll `date` is already a local work date, so we bucket by calendar date.
#    - Pages through EVERY page. Fails loud on API error / missing field.
#
#  NOT marked verified.
#
#  Usage:  .\get-overtime.ps1  [-Date yyyy-MM-dd]   (default = yesterday)
# ============================================================================

[CmdletBinding()]
param([string]$Date)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Fail($msg) { Write-Host ""; Write-Host "FAILED: $msg" -ForegroundColor Red; Write-Host ""; exit 1 }

# Scope: the two Service units, matched by payout business-unit NAME (payroll uses names).
$SERVICE_UNITS = @('HVAC - Service', 'Plumbing - Service')

$TokenUrl = 'https://auth.servicetitan.io/connect/token'
$ApiBase  = 'https://api.servicetitan.io'

try { $pac = [TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time') }
catch { Fail "Could not load the 'Pacific Standard Time' zone. $($_.Exception.Message)" }

# Which work day (calendar date). Default = yesterday (Pacific).
if ([string]::IsNullOrWhiteSpace($Date)) {
    $selected = ([TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $pac)).Date.AddDays(-1)
} else {
    try { $selected = [DateTime]::ParseExact($Date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    catch { Fail "Date '$Date' is not valid. Use yyyy-MM-dd." }
}
$dayStr   = $selected.ToString('yyyy-MM-dd')
$dOnAfter = "${dayStr}T00:00:00Z"
$dBefore  = "${dayStr}T23:59:59Z"

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

# --- pull the work day's gross-pay-items ---
$items = Get-AllPages "/payroll/v2/tenant/$tenant/gross-pay-items" @{ dateOnOrAfter = $dOnAfter; dateOnOrBefore = $dBefore }

# --- sum Overtime hours by ACTIVITY x Service unit; verify date + unit client-side ---
$byAct = @{}        # activity -> @{ unitName -> hours }
$unitTotals = @{}; $unitTechs = @{}
foreach ($u in $SERVICE_UNITS) { $unitTotals[$u] = 0.0; $unitTechs[$u] = New-Object 'System.Collections.Generic.HashSet[string]' }

foreach ($it in $items) {
    if ($null -eq $it.PSObject.Properties['paidTimeType']) { Fail "A gross-pay-item ($($it.id)) is missing paidTimeType." }
    if ($it.paidTimeType -ne 'Overtime') { continue }
    if ($null -eq $it.PSObject.Properties['date']) { Fail "Overtime item $($it.id) is missing date." }
    # client-verify the work day (date field is a UTC-midnight calendar date)
    $d = [DateTime]::Parse($it.date, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
    if ($d.ToString('yyyy-MM-dd') -ne $dayStr) { continue }
    if ($null -eq $it.PSObject.Properties['payoutBusinessUnitName']) { Fail "Overtime item $($it.id) is missing payoutBusinessUnitName." }
    $bu = "$($it.payoutBusinessUnitName)"
    if ($SERVICE_UNITS -notcontains $bu) { continue }
    if ($null -eq $it.PSObject.Properties['paidDurationHours']) { Fail "Overtime item $($it.id) is missing paidDurationHours." }
    $hrs = 0.0
    if (-not [double]::TryParse("$($it.paidDurationHours)", [ref]$hrs)) { Fail "Overtime item $($it.id) has a non-numeric paidDurationHours '$($it.paidDurationHours)'." }

    $act = if (($null -ne $it.PSObject.Properties['activity']) -and -not [string]::IsNullOrWhiteSpace([string]$it.activity)) { "$($it.activity)" } else { '(no activity)' }
    if (-not $byAct.ContainsKey($act)) { $byAct[$act] = @{}; foreach ($u in $SERVICE_UNITS) { $byAct[$act][$u] = 0.0 } }
    $byAct[$act][$bu] += $hrs
    $unitTotals[$bu]  += $hrs
    if ($it.employeeId) { [void]$unitTechs[$bu].Add("$($it.employeeId)") }
}

# --- output ---
Write-Host ""
Write-Host "OVERTIME - Service techs (day before)" -ForegroundColor Cyan
Write-Host "Work day    : $dayStr (payroll calendar date)"
Write-Host "Gross-pay-items scanned: $($items.Count)"
Write-Host ""

Write-Host "OT hours by activity type (payout unit):"
$rows = foreach ($a in ($byAct.Keys | Sort-Object)) {
    $h1 = $byAct[$a]['HVAC - Service']; $h2 = $byAct[$a]['Plumbing - Service']
    [PSCustomObject]@{
        'Activity'         = $a
        'HVAC-Service'     = [math]::Round($h1, 1)
        'Plumbing-Service' = [math]::Round($h2, 1)
        'Total'            = [math]::Round($h1 + $h2, 1)
    }
}
$rows | Format-Table -AutoSize | Out-String | Write-Host

$t1 = $unitTotals['HVAC - Service']; $t2 = $unitTotals['Plumbing - Service']
Write-Host ("TOTAL OT hours    HVAC-Service: {0}  ({1} techs)    Plumbing-Service: {2}  ({3} techs)    Grand total: {4}" -f `
    [math]::Round($t1,1), $unitTechs['HVAC - Service'].Count, [math]::Round($t2,1), $unitTechs['Plumbing - Service'].Count, [math]::Round($t1+$t2,1)) -ForegroundColor Green
Write-Host ""
Write-Host "SCOPE/CAVEATS:" -ForegroundColor Yellow
Write-Host " - These are TOTAL overtime CLOCK HOURS, and INCLUDE non-job activities (Idle, Driving, Training)," -ForegroundColor Yellow
Write-Host "   not just job/wrench time. So the number is larger than 'overtime spent on calls'." -ForegroundColor Yellow
Write-Host " - Overtime = paidTimeType 'Overtime' (no separate double-time value exists in the data; if one" -ForegroundColor Yellow
Write-Host "   appears later, confirm with Troy whether it counts). paidDurationHours is decimal HOURS." -ForegroundColor Yellow
Write-Host " - Grouped by the tech's payout/home unit (payoutBusinessUnitName), not the job's unit." -ForegroundColor Yellow
Write-Host " - Day-before only; payroll lag accepted by design." -ForegroundColor Yellow
Write-Host ""
