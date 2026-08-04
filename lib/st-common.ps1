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

# ---- plain-UTC calendar boundaries (NOT Pacific-shifted) --------------------------------------
# The accounting invoices endpoint's `invoiceDate` is a UTC-midnight calendar date (e.g.
# 2026-08-03T00:00:00Z). Day / month / year buckets for revenue MUST therefore use plain
# <date>T00:00:00Z boundaries - do NOT run these through Get-PacDayWindow, which shifts the day
# by +7/8h and would bucket an invoice onto the wrong calendar day. Returns ISO strings the
# invoices endpoint's invoicedOnOrAfter / invoicedOnBefore filters accept.
function Get-UtcDayIso([datetime]$d)   { $d.Date.ToString('yyyy-MM-dd') + 'T00:00:00Z' }
function Get-UtcMonthStart([datetime]$d) { [datetime]::new($d.Year, $d.Month, 1) }
function Get-UtcYearStart([datetime]$d)  { [datetime]::new($d.Year, 1, 1) }

# Fetch accounting invoices whose invoiceDate falls in [StartIso, EndIso) (plain-UTC calendar
# boundaries - see Get-UtcDayIso). Returns one lightweight record per invoice:
#   id (string), buId (businessUnit.id as string), subTotal ([decimal], PRE-TAX, can be negative),
#   invoiceDate (raw ISO string), jobId (job.id as string, or '' when absent - kept for later SILO work).
# HARD RULE: this tenant's invoices endpoint SILENTLY IGNORES a businessUnitIds query param -
# callers MUST filter by buId in code and never trust a server-side BU filter here. pageSize 2500.
function Get-Invoices($Ctx, [string]$StartIso, [string]$EndIso) {
    $raw = Invoke-StPaged $Ctx "/accounting/v2/tenant/$($Ctx.Tenant)/invoices" `
        @{ invoicedOnOrAfter=$StartIso; invoicedOnBefore=$EndIso } 2500
    $out = New-Object System.Collections.ArrayList
    foreach ($i in $raw) {
        foreach ($p in 'id','subTotal','invoiceDate','businessUnit') {
            if ($null -eq $i.PSObject.Properties[$p]) { throw "invoice $($i.id) is missing field '$p'" }
        }
        $buId  = if ($i.businessUnit) { "$($i.businessUnit.id)" } else { '' }
        $jobId = if ($i.job -and -not (Is-EmptyVal $i.job.id)) { "$($i.job.id)" } else { '' }
        [void]$out.Add([pscustomobject]@{
            id          = "$($i.id)"
            buId        = $buId
            subTotal    = [decimal]$i.subTotal
            invoiceDate = "$($i.invoiceDate)"
            jobId       = $jobId
        })
    }
    ,$out
}

# ---- Reporting API v2: run a saved report -----------------------------------------------------
# POSTs to the report data endpoint, pages on hasMore (pageSize default 5000 - a full year of the
# SILO report fits in one page), and RETRIES on HTTP 429 honoring the Retry-After header. This
# tenant's report-run endpoint THROTTLES rapid successive POSTs (verified: two quick pulls -> the
# second returns HTTP 429 "try again in 60 seconds"). Returns @{ fields=@(); rows=@() } where each
# row is a POSITIONAL array - index columns by NAME via Get-ReportColMap, never a hard-coded index.
function Invoke-StReport {
    param($Ctx, [string]$Category, [string]$ReportId, [hashtable]$Body, [int]$PageSize = 5000)
    $allRows = New-Object System.Collections.ArrayList
    $fields = $null; $page = 1; $maxPages = 200
    $json = ($Body | ConvertTo-Json -Depth 8)
    while ($true) {
        $url = "$script:ApiBase/reporting/v2/tenant/$($Ctx.Tenant)/report-category/$Category/reports/$ReportId/data?page=$page&pageSize=$PageSize"
        $resp = Invoke-StReportPost $Ctx $url $json
        if ($null -eq $resp.PSObject.Properties['fields']) { throw "report $ReportId returned no 'fields' field" }
        if ($null -eq $fields) { $fields = @($resp.fields) }
        if ($resp.data) { [void]$allRows.AddRange(@($resp.data)) }
        if (-not $resp.hasMore) { break }
        $page++; if ($page -gt $maxPages) { throw "report $ReportId paging exceeded $maxPages pages" }
    }
    @{ fields = $fields; rows = $allRows }
}
# Single POST with 429 retry+backoff. Retry-After header is honored when present; otherwise falls
# back to 60s (the tenant's stated cooldown). Any non-429 failure fails loud immediately.
function Invoke-StReportPost($Ctx, [string]$Url, [string]$JsonBody) {
    $maxRetries = 5
    for ($attempt = 0; $attempt -le $maxRetries; $attempt++) {
        try {
            return Invoke-RestMethod -Method Post -Uri $Url -Headers $Ctx.Headers -ContentType 'application/json' -Body $JsonBody
        } catch {
            $st = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($st -eq 429 -and $attempt -lt $maxRetries) {
                $wait = 0
                try { $ra = $_.Exception.Response.Headers['Retry-After']; if ($ra) { [int]::TryParse("$ra", [ref]$wait) | Out-Null } } catch { }
                if ($wait -le 0) { $wait = 60 }
                Start-Sleep -Seconds $wait
                continue
            }
            throw "report POST failed (HTTP $st)"
        }
    }
    throw "report POST kept returning HTTP 429 after $maxRetries retries"
}
# fields[] (each {name,label}) -> @{ columnName = columnIndex }. Rows are positional arrays; use
# this to index by column NAME. Pass required column names to assert they exist (fail loud if not).
function Get-ReportColMap($fields, [string[]]$Require = @()) {
    $m = @{}
    for ($i = 0; $i -lt $fields.Count; $i++) { $m["$($fields[$i].name)"] = $i }
    foreach ($r in $Require) { if (-not $m.ContainsKey($r)) { throw "report is missing expected column '$r'" } }
    $m
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
