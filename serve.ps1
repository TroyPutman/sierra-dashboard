# ============================================================================
#  serve.ps1  --  PRESENTATION SERVER (layer 3)
#  Serves dashboard.html and /api/metrics?date=YYYY-MM-DD (JSON snapshot).
#  Past days: served frozen from data/<date>.json ONLY if that cache is final (computed after the
#  Pacific day ended); a stale mid-day partial is recomputed on demand and re-frozen. Today:
#  recomputed when the cached file is older than the TTL. First pull of a fresh day is slow.
#  /api/silo-flip is a READ-ONLY passthrough of data/silo-flip.json (never computed here).
#    .\serve.ps1              # http://localhost:8787
#    .\serve.ps1 -Port 9000
# ============================================================================
[CmdletBinding()]
param([int]$Port = 8787)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/metrics.ps1')

# --- version / staleness self-report (see HANDOFF: long-running server keeps startup-time code) ---
# CODE files = only what is dot-sourced once at startup. dashboard.html is served fresh every request,
# so it is deliberately excluded here.
$CODE_FILES = @(
    (Join-Path $PSScriptRoot 'serve.ps1'),
    (Join-Path $PSScriptRoot 'lib/metrics.ps1'),
    (Join-Path $PSScriptRoot 'lib/st-common.ps1')
)
function Get-CodeMtimeUtc {
    ($CODE_FILES | ForEach-Object { (Get-Item $_).LastWriteTimeUtc } | Sort-Object -Descending | Select-Object -First 1)
}
$SERVER_START_UTC     = (Get-Date).ToUniversalTime()
$LOADED_CODE_MTIME_UTC = Get-CodeMtimeUtc

$dataDir = Join-Path $PSScriptRoot 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$secretsPath = Join-Path $PSScriptRoot 'secrets.json'
$htmlPath    = Join-Path $PSScriptRoot 'dashboard.html'
$TODAY_TTL   = 300     # seconds; recompute today if the cached file is older than this
$SILO_CUR_TTL= 21600   # seconds; the CURRENT month recomputes at most every 6h (a full month is ~2 min)

# A cached past-day file is trusted ONLY if it is final: computed after that Pacific day ended.
# A mid-day snapshot (isToday=true, or generatedAt before the day's Pacific-midnight end) is a
# PARTIAL and must never be served as final. Returns $true only for a genuinely complete day.
function Test-SnapshotFinal([string]$file, [datetime]$date, $pac) {
    if (-not (Test-Path $file)) { return $false }
    try { $parsed = Get-Content $file -Raw | ConvertFrom-Json } catch { return $false }
    if ($null -eq $parsed) { return $false }
    # explicit flag (written by the current Build-Snapshot) is authoritative
    if ($parsed.PSObject.Properties['final'] -and $parsed.final) { return $true }
    # legacy files with no 'final' flag: infer it. A snapshot captured while the day was still
    # "today" is partial; otherwise it is final only if generated at/after the day's Pacific end.
    if ($parsed.isToday) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$parsed.generatedAt)) { return $false }
    try {
        $gen = [DateTime]::Parse([string]$parsed.generatedAt, [Globalization.CultureInfo]::InvariantCulture,
            ([Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal))
    } catch { return $false }
    $dayEndUtc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($date.Date.AddDays(1), 'Unspecified'), $pac)
    return ($gen -ge $dayEndUtc)
}

function Get-SnapshotJson([string]$dateStr) {
    $pac = Get-Pac; $today = Get-TodayPac $pac
    $date = [DateTime]::ParseExact($dateStr, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $canon = $date.ToString('yyyy-MM-dd')                 # canonical -> safe filename
    $file = Join-Path $dataDir "$canon.json"
    $isToday = ($date.Date -eq $today)
    if ($isToday) {
        # Today: serve cache while it is younger than the TTL; otherwise recompute (climbs live).
        if (Test-Path $file) {
            $age = ((Get-Date).ToUniversalTime() - (Get-Item $file).LastWriteTimeUtc).TotalSeconds
            if ($age -lt $TODAY_TTL) { return (Get-Content $file -Raw) }
        }
    } else {
        # Past (or non-today) date: serve cache ONLY if it is final. A stale mid-day partial is
        # ignored here and recomputed below from the now-complete data, then re-frozen as final.
        if (Test-SnapshotFinal $file $date $pac) { return (Get-Content $file -Raw) }
    }
    $ctx = New-StContext -SecretsPath $secretsPath
    $snap = Build-Snapshot $ctx $date $today
    $json = $snap | ConvertTo-Json -Depth 12
    $json | Set-Content -Path $file -Encoding UTF8
    return $json
}

# A cached SILO month is trusted (served instantly) only when it is final: a past month, computed once.
function Test-SiloFinal([string]$file) {
    if (-not (Test-Path $file)) { return $false }
    try { $p = Get-Content $file -Raw | ConvertFrom-Json } catch { return $false }
    return ($p.final -eq $true)
}
function Get-SiloJson([string]$monthStr) {
    $pac = Get-Pac; $today = Get-TodayPac $pac
    $curFirst = [datetime](Get-Date -Year $today.Year -Month $today.Month -Day 1)
    if ([string]::IsNullOrWhiteSpace($monthStr)) { $monthStr = $curFirst.AddMonths(-1).ToString('yyyy-MM') }
    try { $mFirst = [DateTime]::ParseExact("$monthStr-01",'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture) }
    catch { throw "bad month '$monthStr' (expected yyyy-MM)" }
    $canon = $mFirst.ToString('yyyy-MM'); $file = Join-Path $dataDir "silo-$canon.json"
    $isCurrent = ($mFirst.Year -eq $curFirst.Year -and $mFirst.Month -eq $curFirst.Month)
    if ($isCurrent) {
        # current month: grows through the month; recompute only when the cache is older than the TTL
        if (Test-Path $file) {
            $age = ((Get-Date).ToUniversalTime() - (Get-Item $file).LastWriteTimeUtc).TotalSeconds
            if ($age -lt $SILO_CUR_TTL) { return (Get-Content $file -Raw) }
        }
    } else {
        # past month: served only if final; a partial (computed mid-month) is recomputed once and re-frozen
        if (Test-SiloFinal $file) { return (Get-Content $file -Raw) }
    }
    $ctx = New-StContext -SecretsPath $secretsPath
    $snap = Build-SiloSnapshot $ctx $mFirst $curFirst
    $json = $snap | ConvertTo-Json -Depth 12
    $json | Set-Content -Path $file -Encoding UTF8
    return $json
}

# --- SILO flip rate (TGLs created / ROPP calls ran) : READ-ONLY cache passthrough --------------
# This endpoint NEVER computes on request. A full pull is ~5-6 min of 429-throttled Reporting API
# POSTs, which would hang the HTTP request; SILO-FLIP-HANDOFF.md 7.3 and 8.4/9 forbid it outright.
# So: do NOT call Build-SiloFlipSnapshot from serve.ps1. The ONLY producer of data/silo-flip.json
# is refresh-silo-flip.ps1 (run by the GitHub Actions workflow and manually), and that script owns
# freshness -- there is deliberately NO TTL / recompute logic here.
# If the cache is missing, unreadable, or has no 'block', we FAIL LOUD with an error-shaped payload
# instead of inventing or reusing a number (CLAUDE.md rule 1).
$SILO_FLIP_FILE  = 'data/silo-flip.json'
$SILO_FLIP_TITLE = 'SILO flip rate (TGLs created / ROPP calls ran)'

function New-SiloFlipErrorJson([string]$msg) {
    @{
        asOf        = $null
        final       = $false
        generatedAt = (Get-UtcNow)
        block       = (New-ErrorBlock 'silo-flip' $SILO_FLIP_TITLE $msg)
    } | ConvertTo-Json -Depth 12
}

function Get-SiloFlipJson {
    $file = Join-Path $dataDir 'silo-flip.json'
    $fix  = "Run .\refresh-silo-flip.ps1 to (re)build it -- this figure is precomputed, never computed on request."
    if (-not (Test-Path $file)) {
        return (New-SiloFlipErrorJson "SILO flip cache '$SILO_FLIP_FILE' is missing. $fix")
    }
    try { $raw = Get-Content $file -Raw }
    catch {
        return (New-SiloFlipErrorJson "SILO flip cache '$SILO_FLIP_FILE' could not be read: $($_.Exception.Message). $fix")
    }
    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json } catch { $parsed = $null }
    if ($null -eq $parsed -or -not $parsed.PSObject.Properties['block'] -or $null -eq $parsed.block) {
        return (New-SiloFlipErrorJson "SILO flip cache '$SILO_FLIP_FILE' is unreadable or has no 'block'. $fix")
    }
    return $raw     # served exactly as written by refresh-silo-flip.ps1
}

# Formats a UTC datetime as a Pacific "yyyy-MM-dd HH:mm" string, matching To-PacStr's convention
# (lib/st-common.ps1) but taking a [datetime] instead of an ISO string.
function Format-PacFromUtc([datetime]$utc) {
    $pac = Get-Pac
    ([TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::SpecifyKind($utc, 'Utc'), $pac)).ToString('yyyy-MM-dd HH:mm')
}

function Get-VersionJson {
    $currentCodeMtimeUtc = Get-CodeMtimeUtc
    $isStale = ($currentCodeMtimeUtc -gt $LOADED_CODE_MTIME_UTC)
    @{
        serverStart          = $SERVER_START_UTC.ToString('o')
        serverStartPac       = Format-PacFromUtc $SERVER_START_UTC
        loadedCodeMtime      = $LOADED_CODE_MTIME_UTC.ToString('o')
        loadedCodeMtimePac   = Format-PacFromUtc $LOADED_CODE_MTIME_UTC
        currentCodeMtime     = $currentCodeMtimeUtc.ToString('o')
        currentCodeMtimePac  = Format-PacFromUtc $currentCodeMtimeUtc
        stale                = $isStale
    } | ConvertTo-Json
}

function Write-Resp($res, [int]$code, [string]$type, [string]$body) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $res.StatusCode = $code
    $res.ContentType = $type
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
    $res.OutputStream.Close()
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Sierra dashboard server running." -ForegroundColor Green
Write-Host ("Open in your browser:  http://localhost:{0}" -f $Port) -ForegroundColor Cyan
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray

while ($listener.IsListening) {
    $ctxHttp = $listener.GetContext()
    $req = $ctxHttp.Request; $res = $ctxHttp.Response
    try {
        $path = $req.Url.AbsolutePath
        if ($path -eq '/' -or $path -eq '/index.html' -or $path -eq '/dashboard.html') {
            Write-Resp $res 200 'text/html; charset=utf-8' (Get-Content $htmlPath -Raw)
        }
        elseif ($path -eq '/api/metrics') {
            $dateStr = $req.QueryString['date']
            if ([string]::IsNullOrWhiteSpace($dateStr)) { $dateStr = (Get-TodayPac (Get-Pac)).ToString('yyyy-MM-dd') }
            try {
                $json = Get-SnapshotJson $dateStr
                Write-Resp $res 200 'application/json; charset=utf-8' $json
            } catch {
                $err = @{ error = "Could not build snapshot: $($_.Exception.Message)"; date = $dateStr } | ConvertTo-Json
                Write-Resp $res 500 'application/json; charset=utf-8' $err
            }
        }
        elseif ($path -eq '/api/silo') {
            $monthStr = $req.QueryString['month']
            try {
                $json = Get-SiloJson $monthStr
                Write-Resp $res 200 'application/json; charset=utf-8' $json
            } catch {
                $err = @{ error = "Could not build SILO snapshot: $($_.Exception.Message)"; month = $monthStr } | ConvertTo-Json
                Write-Resp $res 500 'application/json; charset=utf-8' $err
            }
        }
        elseif ($path -eq '/api/silo-flip') {
            # Read-only: returns the precomputed data/silo-flip.json (see Get-SiloFlipJson).
            # A missing/unreadable cache still returns 200 with an error-shaped block so the
            # dashboard renders its standard fail-loud banner rather than a blank section.
            try {
                $json = Get-SiloFlipJson
                Write-Resp $res 200 'application/json; charset=utf-8' $json
            } catch {
                $err = @{ error = "Could not read SILO flip cache: $($_.Exception.Message)" } | ConvertTo-Json
                Write-Resp $res 500 'application/json; charset=utf-8' $err
            }
        }
        elseif ($path -eq '/api/version') {
            try {
                Write-Resp $res 200 'application/json; charset=utf-8' (Get-VersionJson)
            } catch {
                $err = @{ error = "Could not build version info: $($_.Exception.Message)" } | ConvertTo-Json
                Write-Resp $res 500 'application/json; charset=utf-8' $err
            }
        }
        elseif ($path -eq '/favicon.ico') { Write-Resp $res 204 'text/plain' '' }
        else { Write-Resp $res 404 'text/plain' 'not found' }
    } catch {
        try { Write-Resp $res 500 'text/plain' 'server error' } catch {}
    }
}
