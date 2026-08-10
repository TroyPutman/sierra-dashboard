# ============================================================================
#  refresh-silo-flip.ps1  --  pull the SILO flip rate to data/silo-flip.json
#  The flip rate is (TGLs created) / (ROPP calls ran) for MTD + YTD - the SILO manager's own
#  definition. See the M-SiloFlip header block in lib/metrics.ps1 for the full method and
#  SILO-FLIP-HANDOFF.md for the investigation it came from.
#
#  WHY THIS IS ITS OWN SCRIPT, AND WHY IT SKIPS MOST RUNS:
#    A full compute is 4 Reporting-API POSTs spaced ~65s apart (this tenant 429-throttles rapid
#    report runs with a ~60s cooldown) plus a bulk jobs pull => roughly 5-6 MINUTES. The deploy
#    workflow refreshes every 15 minutes and normally finishes in ~2-3 minutes, so recomputing
#    this on every run would more than double the job and burn report-API quota to re-derive a
#    number that barely moves. Hence the TTL GATE below: the cache is treated as fresh for
#    siloFlip.cacheTtlSeconds (config.json; 6 hours today), so the every-15-minutes job stays at
#    its usual ~2-3 minutes and a full recompute happens only every few hours. That is the whole
#    point of this script - the metric itself lives in lib/metrics.ps1.
#
#  A RECOMPUTE HAPPENS WHEN (any of):
#    * -Force was passed
#    * data/silo-flip.json does not exist
#    * it is unreadable / not valid JSON / missing its asOf|generatedAt|block keys
#    * its asOf is not TODAY's Pacific date (a new Pacific day always recomputes)
#    * its generatedAt is older than siloFlip.cacheTtlSeconds
#  Otherwise the script prints why it skipped and exits 0 within a second or two.
#
#    .\refresh-silo-flip.ps1          # TTL-gated (what CI runs)
#    .\refresh-silo-flip.ps1 -Force   # recompute now, ignore the TTL (~5-6 min)
#
#  NOT FROZEN: `final` is always false. The figure is retroactive (TGLs keep getting scheduled
#  onto days already counted), so it keeps settling upward and is never final.
#
#  EVERY RECOMPUTE PRINTS the per-rule drop counts and both periods' num/den/rate. The cleaning
#  rules are currently no-ops on live data (handoff SS5.1), so printing them is what makes a future
#  edit to either saved report VISIBLE instead of a silent shift in the number.
#
#  FAILS LOUD: $ErrorActionPreference=Stop; the config block is validated BEFORE any API call, so
#  a missing report id fails in a second rather than five minutes in. A build failure is captured
#  as a status='error' block in the cache (same as refresh-silo.ps1) so the dashboard shows the
#  error on screen instead of a stale number. Passes NO pageSize=300 anywhere.
# ============================================================================
[CmdletBinding()]
param([switch]$Force)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/metrics.ps1')

$dataDir = Join-Path $PSScriptRoot 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$file        = Join-Path $dataDir 'silo-flip.json'
$secretsPath = Join-Path $PSScriptRoot 'secrets.json'

# Validate config.json -> siloFlip FIRST (report ids, tag ids, expected columns, timings). This
# throws a precise message for anything missing, before a token is fetched or a minute is spent.
$cfg = Get-SiloFlipConfig
$ttl = $cfg.cacheTtlSeconds

$pac      = Get-Pac
$today    = Get-TodayPac $pac
$todayStr = $today.ToString('yyyy-MM-dd')

# ---- TTL gate -------------------------------------------------------------------------------
# The two cache fields are read out of the RAW file text with a regex rather than off the
# ConvertFrom-Json object on purpose: Windows PowerShell 5.1's ConvertFrom-Json silently coerces an
# ISO-8601-looking JSON string into a [datetime] (in local time) while pwsh7 leaves it a [string].
# Comparing those directly would behave differently on the dev box and on the Linux/UTC CI runner -
# the exact host-typing trap that broke SILO before. The raw bytes are identical on both hosts.
# generatedAt is then parsed with Parse-Utc, which forces an explicit UTC interpretation.
function Get-FlipCacheStaleReason([string]$path, [string]$expectAsOf, [int]$ttlSeconds) {
    if (-not (Test-Path $path)) { return "no cache file yet ($path)" }
    $raw = $null
    try { $raw = Get-Content $path -Raw } catch { return "cache file could not be read" }
    if ([string]::IsNullOrWhiteSpace($raw)) { return "cache file is empty" }
    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json } catch { return "cache file is not valid JSON" }

    # A cached ERROR is always stale, no matter how recent. A failed build still writes a
    # status='error' block (and the workflow commits it), so without this test a single transient
    # API failure would look "fresh" and pin that error on screen for the whole TTL - 6 hours of a
    # visibly broken tile that nothing retries. Reading .block.status off the parsed object is safe
    # here: it is a plain 'ok'/'error' string, not a date, so the PS5.1-vs-pwsh7 coercion trap that
    # forces the regex reads below does not apply.
    if ($null -eq $parsed.block) { return "cache file has no block" }
    if ("$($parsed.block.status)" -ne 'ok') { return "cached block is status='$($parsed.block.status)' - retrying rather than leaving an error on screen for the TTL" }

    $mAsOf = [regex]::Match($raw, '"asOf"\s*:\s*"([^"]*)"')
    $mGen  = [regex]::Match($raw, '"generatedAt"\s*:\s*"([^"]*)"')
    if (-not $mAsOf.Success) { return "cache file has no asOf" }
    if (-not $mGen.Success)  { return "cache file has no generatedAt" }
    if ($raw -notmatch '"block"') { return "cache file has no block" }

    $asOf = $mAsOf.Groups[1].Value
    if ($asOf -ne $expectAsOf) { return "cache is as-of $asOf but today (Pacific) is $expectAsOf" }

    $gen = $null
    try { $gen = Parse-Utc $mGen.Groups[1].Value } catch { $gen = $null }
    if ($null -eq $gen) { return "cache generatedAt '$($mGen.Groups[1].Value)' is unparseable" }
    $ageSec = ([DateTime]::UtcNow - $gen).TotalSeconds
    if ($ageSec -ge $ttlSeconds) { return ("cache is {0:N0}s old (TTL {1}s)" -f $ageSec, $ttlSeconds) }

    # Fresh: return $null and report the remaining life to the caller for the skip message.
    Write-Host ("SILO flip cache is fresh: as-of $expectAsOf, {0:N0}s old, TTL {1}s ({2:N0}s left) - skipping the ~5-6 min recompute." -f $ageSec, $ttlSeconds, ($ttlSeconds - $ageSec))
    $null
}

if ($Force) {
    Write-Host "-Force: recomputing regardless of cache age."
} else {
    $stale = Get-FlipCacheStaleReason $file $todayStr $ttl
    if ($null -eq $stale) { exit 0 }
    Write-Host "Recomputing SILO flip: $stale"
}

# ---- recompute ------------------------------------------------------------------------------
Write-Host ("[{0}] building SILO flip snapshot as of {1} (4 report POSTs {2}s apart - expect ~5-6 min) ..." -f (Get-Date).ToString('HH:mm:ss'), $todayStr, $cfg.postSpacingSeconds)
$ctx  = New-StContext -SecretsPath $secretsPath
$snap = Build-SiloFlipSnapshot $ctx $today
($snap | ConvertTo-Json -Depth 12) | Set-Content -Path $file -Encoding UTF8

$b = $snap.block
if ($b.status -ne 'ok') {
    Write-Host ("   wrote $file  (final=$($snap.final), status=ERROR: $($b.error))") -ForegroundColor Red
    return
}

Write-Host ("   wrote $file  (final=$($snap.final), status=ok)") -ForegroundColor Green
foreach ($p in 'mtd','ytd') {
    $x = $b.periods[$p]
    $rate = '-'
    if ($null -ne $x.rate) { $rate = "{0:N2}%" -f $x.rate }
    Write-Host ("   {0}: {1} TGLs / {2} calls ran = {3}" -f $p.ToUpper(), $x.num, $x.den, $rate)
    # Per-rule drop counts: these paths are no-ops on today's data, so printing them every run is
    # how an edit to either saved report becomes visible instead of silently moving the number.
    $d = $b.diagnostics[$p]
    Write-Host ("        raw rows num/den {0}/{1}   distinct jobs {2}   jobs pulled {3}" -f $d.rawNumeratorRows, $d.rawDenominatorRows, $d.distinctJobNumbers, $d.jobsPulled)
    Write-Host ("        dropped: mgmt-removed {0}   not-ROPP {1}   not-completed-not-TGL-source {2}   |   failed open (job not found) {3}" -f $d.droppedManagementRemoved, $d.droppedNotRopp, $d.droppedNotCompletedNotTglSource, $d.failedOpen)
    Write-Host ("        window guard: out-of-window rows {0} (must be 0)   rows with no ISO date prefix {1}" -f $d.outOfWindowRows, $d.unparsedDateRows)
}
