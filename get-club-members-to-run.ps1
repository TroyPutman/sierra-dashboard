# ============================================================================
#  get-club-members-to-run.ps1  (M6 - built 2026-07-16)
#  CLUB MEMBERS LEFT TO RUN - seasonal maintenance (HVAC). Prints to screen.
#
#  Follows SPEC.md (M6), per Troy's 2026-07-16 decision:
#    - "Left to run" = an ACTIVE HVAC club member with NO completed <season> maintenance
#      in the last <lookback> months. Completion-based set difference.
#    - CONFIG (below): season Cooling now; flip to Heating in the fall = ONE-LINE change.
#      lookback = 16 months. Trade = HVAC (residential SAM memberships; commercial excluded).
#    - Member identity matched at CUSTOMER level for this rough draft (location/system later).
#    - Pages through EVERY page. Fails loud on API error / missing field.
#
#  API notes used here (verified 2026-07-16): jobs `jobTypeId` (singular) filters server-side;
#  plural `jobTypeIds` is ignored - so we loop the season's job-type ids.
#
#  NOT marked verified.
#  Usage:  .\get-club-members-to-run.ps1
# ============================================================================

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Fail($msg) { Write-Host ""; Write-Host "FAILED: $msg" -ForegroundColor Red; Write-Host ""; exit 1 }

# ================== CONFIG (change these for the fall switch) ==================
$SEASON          = 'Cooling'     # 'Cooling' now; change to 'Heating' in the fall
$LOOKBACK_MONTHS = 16
# season -> maintenance job-type NAME pattern
$SEASON_PATTERNS = @{ 'Cooling' = '^SAM Cooling Service'; 'Heating' = '^SAM Heating Service' }
# residential HVAC club membership types (name pattern); excludes 'SAM Commercial Membership'
$MEMBER_TYPE_PATTERN = '^SAM Membership'
# ==============================================================================

if (-not $SEASON_PATTERNS.ContainsKey($SEASON)) { Fail "SEASON '$SEASON' is not configured. Use 'Cooling' or 'Heating'." }
$seasonPattern = $SEASON_PATTERNS[$SEASON]

$TokenUrl = 'https://auth.servicetitan.io/connect/token'
$ApiBase  = 'https://api.servicetitan.io'

try { $pac = [TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time') }
catch { Fail "Could not load the 'Pacific Standard Time' zone. $($_.Exception.Message)" }

$today  = ([TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $pac)).Date
$cutoff = $today.AddMonths(-$LOOKBACK_MONTHS)
$cutoffUtc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($cutoff, 'Unspecified'), $pac)
$cutoffIso = $cutoffUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")

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
    $page = 1; $maxPages = 5000
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

# --- season's maintenance job-type ids (name matches the season pattern) ---
$coolingTypeIds = New-Object System.Collections.ArrayList
foreach ($jt in (Get-AllPages "/jpm/v2/tenant/$tenant/job-types" @{})) {
    if (($null -eq $jt.PSObject.Properties['name']) -or ($null -eq $jt.PSObject.Properties['id'])) { Fail "A job-types record is missing id or name." }
    if ($jt.name -match $seasonPattern) { [void]$coolingTypeIds.Add("$($jt.id)") }
}
if ($coolingTypeIds.Count -eq 0) { Fail "No job types matched the $SEASON pattern '$seasonPattern'." }

# --- residential HVAC club membership-type ids ---
$memberTypeIds = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($mt in (Get-AllPages "/memberships/v2/tenant/$tenant/membership-types" @{})) {
    if ($null -eq $mt.PSObject.Properties['name']) { continue }
    if ($mt.name -match $MEMBER_TYPE_PATTERN) { [void]$memberTypeIds.Add("$($mt.id)") }
}
if ($memberTypeIds.Count -eq 0) { Fail "No membership types matched '$MEMBER_TYPE_PATTERN'." }

# --- member base: active residential HVAC memberships -> distinct customerId ---
$memberCustomers = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($m in (Get-AllPages "/memberships/v2/tenant/$tenant/memberships" @{ status = 'Active' })) {
    if ($null -eq $m.PSObject.Properties['membershipTypeId']) { Fail "A membership ($($m.id)) is missing membershipTypeId." }
    if (-not $memberTypeIds.Contains("$($m.membershipTypeId)")) { continue }
    if ($null -eq $m.PSObject.Properties['customerId']) { Fail "Membership $($m.id) is missing customerId." }
    [void]$memberCustomers.Add("$($m.customerId)")
}

# --- ran-recently: distinct customers with a completed <season> maintenance since cutoff ---
$ranCustomers = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($tid in $coolingTypeIds) {
    foreach ($j in (Get-AllPages "/jpm/v2/tenant/$tenant/jobs" @{ jobStatus='Completed'; completedOnOrAfter=$cutoffIso; jobTypeId=$tid })) {
        if ($null -eq $j.PSObject.Properties['customerId']) { Fail "Completed job $($j.id) is missing customerId." }
        [void]$ranCustomers.Add("$($j.customerId)")
    }
}

# --- set difference ---
$ranAmongMembers = 0
foreach ($c in $memberCustomers) { if ($ranCustomers.Contains($c)) { $ranAmongMembers++ } }
$leftToRun = $memberCustomers.Count - $ranAmongMembers
$pct = if ($memberCustomers.Count -gt 0) { "{0:N1}%" -f (100.0 * $leftToRun / $memberCustomers.Count) } else { 'n/a' }

# --- output ---
Write-Host ""
Write-Host "CLUB MEMBERS LEFT TO RUN - $SEASON maintenance (HVAC)" -ForegroundColor Cyan
Write-Host "Config      : season=$SEASON, lookback=$LOOKBACK_MONTHS months"
Write-Host "Cutoff date : completed on/after $($cutoff.ToString('yyyy-MM-dd')) counts as 'ran'"
Write-Host "Season job types matched: $($coolingTypeIds.Count) ; club membership types matched: $($memberTypeIds.Count)"
Write-Host ""
Write-Host ("Active HVAC club members (distinct customers) : {0}" -f $memberCustomers.Count)
Write-Host ("  ran $SEASON maintenance in last $LOOKBACK_MONTHS mo : {0}" -f $ranAmongMembers)
Write-Host ("  LEFT TO RUN                                 : {0}   ({1} of members)" -f $leftToRun, $pct) -ForegroundColor Green
Write-Host ""
Write-Host "CAVEATS (SPEC M6, rough draft):" -ForegroundColor Yellow
Write-Host " - 'Member' matched at CUSTOMER level; a customer with multiple systems/locations counts once." -ForegroundColor Yellow
Write-Host " - HVAC club = active residential 'SAM Membership' types (commercial excluded). Member base printed above so it's checkable." -ForegroundColor Yellow
Write-Host " - Season is config: set `$SEASON='Heating' at the top for the fall switch." -ForegroundColor Yellow
Write-Host ""
