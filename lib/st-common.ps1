# ============================================================================
#  lib/st-common.ps1  --  DATA LAYER (layer 1)
#  Auth, paging, timezone, shared catalogs. Nothing metric-specific.
#  Dot-source this; it defines functions + module-scope constants.
# ============================================================================
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:ApiBase  = 'https://api.servicetitan.io'
$script:TokenUrl = 'https://auth.servicetitan.io/connect/token'
$script:LibRoot  = $PSScriptRoot   # lib/ dir; config.json sits one level up

# The 9 reported business units (Inventory 208554530 excluded).
$script:BU_NAMES = [ordered]@{
    '333'='HVAC - Service'; '337'='HVAC - Install - AOR'; '342817560'='HVAC - Maintenance';
    '370'='HVAC - Sales (NR)'; '340802904'='HVAC - Sales Costco (NR)';
    '353'='Plumbing - Service'; '354'='Plumbing - Maintenance'; '408662213'='Plumbing - Install';
    '595105985'='Plumbing - Drains'
}
$script:HVAC_BUS = @('333','337','342817560','370','340802904')
$script:PLMB_BUS = @('595105985','408662213','354','353')

# Resolve the Pacific time zone in a cross-platform way. Windows uses the id
# 'Pacific Standard Time'; Linux/macOS (e.g. GitHub's ubuntu runners) use the IANA
# id 'America/Los_Angeles'. Same underlying zone / same DST rules either way, so
# Pacific business logic is unchanged. Resolved once and cached.
function Get-Pac {
    if ($script:PacTz) { return $script:PacTz }
    foreach ($id in @('Pacific Standard Time', 'America/Los_Angeles')) {
        try { $script:PacTz = [TimeZoneInfo]::FindSystemTimeZoneById($id); return $script:PacTz } catch { }
    }
    throw "Could not resolve the Pacific time zone (tried 'Pacific Standard Time' and 'America/Los_Angeles')"
}
function Get-UtcNow { [DateTime]::UtcNow.ToString("o") }
function Get-TodayPac($Pac) { ([TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $Pac)).Date }

function Parse-Utc([string]$s) {
    [DateTime]::Parse($s, [Globalization.CultureInfo]::InvariantCulture,
        ([Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal))
}
function To-PacStr($Ctx, [string]$s) {
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    ([TimeZoneInfo]::ConvertTimeFromUtc((Parse-Utc $s), $Ctx.Pac)).ToString('yyyy-MM-dd HH:mm')
}
function Is-EmptyVal($v) {
    if ($null -eq $v) { return $true }
    if (($v -is [string]) -and ($v.Trim() -eq '')) { return $true }
    if (($v -is [int] -or $v -is [long] -or $v -is [double]) -and ($v -eq 0)) { return $true }
    $false
}

function New-StContext {
    param([string]$SecretsPath)
    if (-not (Test-Path $SecretsPath)) { throw "secrets.json not found at $SecretsPath" }
    $sec = Get-Content $SecretsPath -Raw | ConvertFrom-Json
    foreach ($f in 'clientId','clientSecret','appKey','tenantId') {
        if ([string]::IsNullOrWhiteSpace($sec.$f)) { throw "secrets.json is missing '$f'" }
    }
    $tok = Invoke-RestMethod -Method Post -Uri $script:TokenUrl -ContentType 'application/x-www-form-urlencoded' `
        -Body @{ grant_type='client_credentials'; client_id=$sec.clientId; client_secret=$sec.clientSecret }
    if ([string]::IsNullOrWhiteSpace($tok.access_token)) { throw "auth server returned no access_token" }
    @{
        Headers = @{ 'Authorization' = "Bearer $($tok.access_token)"; 'ST-App-Key' = $sec.appKey }
        Tenant  = $sec.tenantId
        Pac     = Get-Pac
        Cache   = @{}
    }
}

function Invoke-StPaged {
    param($Ctx, [string]$Path, [hashtable]$Params = @{}, [int]$PageSize = 200)
    $all = New-Object System.Collections.ArrayList
    $page = 1; $max = 5000
    while ($true) {
        $pairs = @()
        foreach ($k in $Params.Keys) { $pairs += ("{0}={1}" -f $k, [uri]::EscapeDataString([string]$Params[$k])) }
        $pairs += "pageSize=$PageSize"; $pairs += "page=$page"
        $url = "$script:ApiBase$Path" + "?" + ($pairs -join '&')
        try { $resp = Invoke-RestMethod -Method Get -Uri $url -Headers $Ctx.Headers }
        catch {
            $st = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'n/a' }
            throw "GET $Path page $page failed (HTTP $st)"
        }
        if ($null -eq $resp.PSObject.Properties['data']) { throw "response from $Path had no 'data' field" }
        if ($resp.data) { [void]$all.AddRange(@($resp.data)) }
        if (-not $resp.hasMore) { break }
        $page++; if ($page -gt $max) { throw "paging exceeded $max pages on $Path" }
    }
    ,$all
}

# ---- cached catalogs (loaded once per context) ----
function Get-JobTypeMap($Ctx) {
    if ($Ctx.Cache.ContainsKey('jobTypes')) { return $Ctx.Cache['jobTypes'] }
    $m = @{}
    foreach ($jt in (Invoke-StPaged $Ctx "/jpm/v2/tenant/$($Ctx.Tenant)/job-types")) {
        if (($null -eq $jt.PSObject.Properties['id']) -or ($null -eq $jt.PSObject.Properties['name'])) { throw "a job-type is missing id/name" }
        $m["$($jt.id)"] = $jt.name
    }
    $Ctx.Cache['jobTypes'] = $m; $m
}
function Get-UserMap($Ctx) {
    if ($Ctx.Cache.ContainsKey('users')) { return $Ctx.Cache['users'] }
    $m = @{}
    foreach ($e in (Invoke-StPaged $Ctx "/settings/v2/tenant/$($Ctx.Tenant)/employees"))   { $m["$($e.id)"] = $e.name }
    foreach ($e in (Invoke-StPaged $Ctx "/settings/v2/tenant/$($Ctx.Tenant)/technicians")) { if (-not $m.ContainsKey("$($e.id)")) { $m["$($e.id)"] = $e.name } }
    $Ctx.Cache['users'] = $m; $m
}
function Get-CancelReasonMap($Ctx) {
    if ($Ctx.Cache.ContainsKey('cancelReasons')) { return $Ctx.Cache['cancelReasons'] }
    $m = @{}
    foreach ($r in (Invoke-StPaged $Ctx "/jpm/v2/tenant/$($Ctx.Tenant)/job-cancel-reasons")) { $m["$($r.id)"] = $r.name }
    $Ctx.Cache['cancelReasons'] = $m; $m
}
# technician id -> home business unit id (for the call board capacity denominator)
function Get-TechBUMap($Ctx) {
    if ($Ctx.Cache.ContainsKey('techBU')) { return $Ctx.Cache['techBU'] }
    $m = @{}
    foreach ($tch in (Invoke-StPaged $Ctx "/settings/v2/tenant/$($Ctx.Tenant)/technicians")) { $m["$($tch.id)"] = "$($tch.businessUnitId)" }
    $Ctx.Cache['techBU'] = $m; $m
}
# campaign id -> @{ name; cat }  (cat = category name; source of the marketing-source mapping)
function Get-CampaignMap($Ctx) {
    if ($Ctx.Cache.ContainsKey('campaigns')) { return $Ctx.Cache['campaigns'] }
    $m = @{}
    foreach ($c in (Invoke-StPaged $Ctx "/marketing/v2/tenant/$($Ctx.Tenant)/campaigns")) {
        $catName = if ($c.category -and $c.category.name) { "$($c.category.name)" } else { '' }
        $m["$($c.id)"] = @{ name = "$($c.name)"; cat = $catName }
    }
    $Ctx.Cache['campaigns'] = $m; $m
}
# dashboard config (config.json at project root); cached. Returns parsed object or $null.
function Get-DashConfig {
    if ($null -ne $script:__dashcfg_loaded) { return $script:__dashcfg }
    $script:__dashcfg_loaded = $true
    $p = Join-Path (Split-Path $script:LibRoot -Parent) 'config.json'
    if (Test-Path $p) { try { $script:__dashcfg = Get-Content $p -Raw | ConvertFrom-Json } catch { $script:__dashcfg = $null } }
    else { $script:__dashcfg = $null }
    $script:__dashcfg
}

# batch-fetch jobs by id (server has no multi-BU filter; we filter client-side)
function Get-JobsByIds($Ctx, $ids) {
    $map = @{}; $arr = @($ids); $chunk = 50
    for ($i = 0; $i -lt $arr.Count; $i += $chunk) {
        $slice = $arr[$i..([Math]::Min($i + $chunk - 1, $arr.Count - 1))]
        foreach ($j in (Invoke-StPaged $Ctx "/jpm/v2/tenant/$($Ctx.Tenant)/jobs" @{ ids = ($slice -join ',') })) { $map["$($j.id)"] = $j }
    }
    $missing = @($arr | Where-Object { -not $map.ContainsKey($_) })
    if ($missing.Count -gt 0) { throw "$($missing.Count) job id(s) could not be fetched (e.g. $($missing[0]))" }
    $map
}

# Pacific-day UTC window for a [datetime]
function Get-PacDayWindow($Ctx, [datetime]$Date) {
    $startLocal = [DateTime]::SpecifyKind($Date.Date, 'Unspecified')
    $startUtc = [TimeZoneInfo]::ConvertTimeToUtc($startLocal, $Ctx.Pac)
    $endUtc   = [TimeZoneInfo]::ConvertTimeToUtc($startLocal.AddDays(1), $Ctx.Pac)
    @{ StartUtc=$startUtc; EndUtc=$endUtc;
       StartIso=$startUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ");
       EndIso=$endUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ") }
}

# new-opportunity filter (M1/M3): recallForId empty AND warrantyId empty AND job type name not recall/warranty/parts-install
function Test-NewOpportunity($job, $jobTypes) {
    foreach ($p in 'recallForId','warrantyId','jobTypeId','businessUnitId') {
        if ($null -eq $job.PSObject.Properties[$p]) { throw "job $($job.id) is missing field '$p'" }
    }
    if (-not (Is-EmptyVal $job.recallForId)) { return $false }
    if (-not (Is-EmptyVal $job.warrantyId))  { return $false }
    $tid = "$($job.jobTypeId)"
    if (-not $jobTypes.ContainsKey($tid)) { throw "job $($job.id) jobTypeId $tid not resolvable" }
    $n = $jobTypes[$tid]
    if ([string]::IsNullOrWhiteSpace($n)) { throw "job type $tid has an empty name" }
    if ($n -match 'recall|warranty|part.*install') { return $false }
    $true
}
