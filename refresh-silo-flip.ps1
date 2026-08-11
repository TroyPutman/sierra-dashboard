# ============================================================================
#  refresh-silo-flip.ps1  --  pull the SILO flip rate to data/silo-flip.json
#  The flip rate is (TGLs created) / (ROPP calls ran) for THREE periods - TODAY (Pacific), MTD and
#  YTD - the SILO manager's own definition. See the M-SiloFlip header block in lib/metrics.ps1 for
#  the full method and SILO-FLIP-HANDOFF.md for the investigation it came from.
#
#  WHY THIS IS ITS OWN SCRIPT, AND WHY IT SKIPS MOST RUNS:
#    A FULL compute is 6 Reporting-API POSTs spaced ~65s apart (this tenant 429-throttles rapid
#    report runs with a ~60s cooldown) plus a ~42,000-job bulk pull covering the whole year =>
#    roughly 7-8 MINUTES. The deploy workflow refreshes every 15 minutes and normally finishes in
#    ~2-3 minutes, so recomputing this on every run would triple the job and burn report-API quota
#    to re-derive a year-to-date number that barely moves. Hence the TTL GATES below.
#
#  THREE OUTCOMES, TWO CLOCKS, TWO DIFFERENT COSTS:
#    * FULL recompute       - all three periods. 6 report POSTs + a ~42k-job pull. ~7-8 min.
#                             Gated on siloFlip.cacheTtlSeconds (6h): a YTD figure off ~4,900 calls
#                             does not move meaningfully in six hours.
#    * TODAY-ONLY recompute - today's period only; the stored MTD/YTD are carried forward VERBATIM.
#                             2 report POSTs + a ONE-DAY jobs pull of a few hundred jobs. ~1-2 min.
#                             Gated on siloFlip.todayTtlSeconds (30m): a single day's figure is a
#                             small sample and goes stale in MINUTES - one TGL can swing it several
#                             points - so a six-hour-old "today" is simply wrong by mid-afternoon.
#    * SKIP                 - nothing to do; exits 0 within a second or two.
#    The cache therefore carries TWO timestamps: `generatedAt` (when MTD/YTD were last built) and
#    `todayGeneratedAt` (when today was last built). A today-only run advances only the second one -
#    if it re-dated `generatedAt` too, every 30-minute run would reset the 6-hour clock and the full
#    rebuild would never happen again.
#
#  DECISION ORDER (first match wins):
#    1. -Force                                                              -> FULL
#    2. no cache file / unreadable / empty / not valid JSON / no block /
#       no generatedAt / unparseable generatedAt                            -> FULL
#    3. cached block is NOT status='ok' (this gates EVERYTHING below):
#         generatedAt older than siloFlip.errorRetryCooldownSeconds         -> FULL
#         otherwise                                                        -> SKIP (a fresh error HOLDS)
#    4. healthy cache, asOf != today's Pacific date                         -> FULL
#       healthy cache, generatedAt older than siloFlip.cacheTtlSeconds      -> FULL
#    5. todayGeneratedAt missing / unparseable / older than
#       siloFlip.todayTtlSeconds                                            -> TODAY-ONLY
#    6. otherwise                                                           -> SKIP
#
#  WHY A FAILED BUILD GATES EVERYTHING (step 3). A failed build still writes a status='error' block,
#  and the workflow commits it. Two bad extremes to avoid: treat it as FRESH and a transient 429
#  pins a visibly broken tile on the wall for 6 hours with nothing retrying it; treat it as ALWAYS
#  STALE and every 15-minute CI run redoes the whole thing - 6 throttled report POSTs plus a ~42k-job
#  pull, on top of the 3 report POSTs refresh.ps1 already makes in the same run. That is what
#  happened on 2026-08-11: the tenant stayed 429-throttled instead of recovering, so the retry was
#  the thing preventing the recovery. So a failure retries on errorRetryCooldownSeconds (~1h), not on
#  the 6h TTL and not every run - and that retry is always a FULL rebuild, never a today-only one,
#  because an errored cache has no trustworthy MTD/YTD left to carry forward. asOf and both TTLs are
#  deliberately NOT consulted for an errored cache: it holds no usable figure, so the only question
#  is WHEN to retry, and a failure must not be retried a minute later merely because the Pacific
#  date rolled over.
#
#    .\refresh-silo-flip.ps1             # gated (what CI runs)
#    .\refresh-silo-flip.ps1 -Force      # FULL recompute now, ignore both clocks (~7-8 min)
#    .\refresh-silo-flip.ps1 -CheckOnly  # print which of the three outcomes, and why; NO network
#
#  NOT FROZEN: `final` is always false. The figure is retroactive (TGLs keep getting scheduled
#  onto days already counted), so it keeps settling upward and is never final.
#
#  EVERY RECOMPUTE PRINTS the per-rule drop counts and each rebuilt period's num/den/rate (all three
#  on a full run, just today on a today-only run). The cleaning rules are currently no-ops on live
#  data (handoff SS5.1), so printing them is what makes a future edit to either saved report VISIBLE
#  instead of a silent shift in the number.
#
#  FAILS LOUD: $ErrorActionPreference=Stop; the config block is validated BEFORE any API call, so
#  a missing report id fails in a second rather than minutes in. A build failure - full OR today-only
#  - is captured as a status='error' block in the cache (same as refresh-silo.ps1) so the dashboard
#  shows the error on screen instead of a stale number. Passes NO pageSize=300 anywhere.
# ============================================================================
[CmdletBinding()]
param([switch]$Force, [switch]$CheckOnly)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/metrics.ps1')

$dataDir = Join-Path $PSScriptRoot 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$file        = Join-Path $dataDir 'silo-flip.json'
$secretsPath = Join-Path $PSScriptRoot 'secrets.json'

# Validate config.json -> siloFlip FIRST (report ids, tag ids, expected columns, target, timings).
# This throws a precise message for anything missing, before a token is fetched or a minute is spent.
$cfg = Get-SiloFlipConfig
$ttl          = $cfg.cacheTtlSeconds
$todayTtl     = $cfg.todayTtlSeconds
$errCooldown  = $cfg.errorRetryCooldownSeconds

$pac      = Get-Pac
$today    = Get-TodayPac $pac
$todayStr = $today.ToString('yyyy-MM-dd')

# ---- the tiered gate ------------------------------------------------------------------------
# Returns @{ mode = 'full' | 'today' | 'skip'; reason = '<why>'; cache = <parsed cache or $null> }.
# `cache` is handed back so a today-only run can carry the stored MTD/YTD forward without reading
# and re-parsing the file a second time.
#
# The three cache timestamps are read out of the RAW file text with a regex rather than off the
# ConvertFrom-Json object on purpose: Windows PowerShell 5.1's ConvertFrom-Json silently coerces an
# ISO-8601-looking JSON string into a [datetime] (in local time) while pwsh7 leaves it a [string].
# Comparing those directly would behave differently on the dev box and on the Linux/UTC CI runner -
# the exact host-typing trap that broke SILO before. The raw bytes are identical on both hosts. Each
# value is then parsed with Parse-Utc, which forces an explicit UTC interpretation.
# The `[{,]\s*` prefix on each pattern is not decoration: without it a bare "generatedAt" pattern
# would be one capital letter away from also matching inside "todayGeneratedAt". Anchoring on the
# JSON key position makes the two keys unambiguous no matter which order they serialize in.
function Get-FlipRefreshDecision([string]$path, [string]$expectAsOf, [int]$ttlSeconds, [int]$todayTtlSeconds, [int]$errorCooldownSeconds) {
    # ---- step 2: anything unusable about the file at all -> FULL --------------------------------
    if (-not (Test-Path $path)) { return @{ mode='full'; reason="no cache file yet ($path)"; cache=$null } }
    $raw = $null
    try { $raw = Get-Content $path -Raw } catch { return @{ mode='full'; reason='cache file could not be read'; cache=$null } }
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{ mode='full'; reason='cache file is empty'; cache=$null } }
    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json } catch { return @{ mode='full'; reason='cache file is not valid JSON'; cache=$null } }
    if ($null -eq $parsed.block) { return @{ mode='full'; reason='cache file has no block'; cache=$null } }

    $mAsOf  = [regex]::Match($raw, '[{,]\s*"asOf"\s*:\s*"([^"]*)"')
    $mGen   = [regex]::Match($raw, '[{,]\s*"generatedAt"\s*:\s*"([^"]*)"')
    $mToday = [regex]::Match($raw, '[{,]\s*"todayGeneratedAt"\s*:\s*"([^"]*)"')
    if (-not $mGen.Success) { return @{ mode='full'; reason='cache file has no generatedAt'; cache=$null } }

    $gen = $null
    try { $gen = Parse-Utc $mGen.Groups[1].Value } catch { $gen = $null }
    if ($null -eq $gen) { return @{ mode='full'; reason="cache generatedAt '$($mGen.Groups[1].Value)' is unparseable"; cache=$null } }
    $ageSec = ([DateTime]::UtcNow - $gen).TotalSeconds

    # ---- step 3: a FAILED build runs on its own, shorter clock and GATES EVERYTHING -------------
    # See the header for why. A failed cache never takes the today-only path: there is no
    # trustworthy MTD/YTD in it to carry forward, so the only honest retry is a full rebuild.
    $status = "$($parsed.block.status)"
    if ($status -ne 'ok') {
        if ($ageSec -ge $errorCooldownSeconds) {
            return @{ mode='full'; cache=$parsed
                      reason=("last build FAILED {0:N0}s ago (error-retry cooldown {1}s) - retrying now with a FULL rebuild" -f $ageSec, $errorCooldownSeconds) }
        }
        Write-Host ("SILO flip cache holds a FAILED build from {0:N0}s ago; error-retry cooldown is {1}s ({2:N0}s left) - NOT retrying yet, so the tenant's 429 throttle can clear. The dashboard keeps showing the error meanwhile (never a stale number)." -f $ageSec, $errorCooldownSeconds, ($errorCooldownSeconds - $ageSec)) -ForegroundColor Yellow
        Write-Host ("   last error: $($parsed.block.error)") -ForegroundColor DarkGray
        return @{ mode='skip'; cache=$parsed
                  reason=("last build FAILED {0:N0}s ago and the error-retry cooldown ({1}s) has not elapsed" -f $ageSec, $errorCooldownSeconds) }
    }

    # ---- step 4: a GOOD build - the FULL-rebuild clock first ------------------------------------
    if (-not $mAsOf.Success) { return @{ mode='full'; reason='cache file has no asOf'; cache=$null } }
    $asOf = $mAsOf.Groups[1].Value
    if ($asOf -ne $expectAsOf) {
        # A new Pacific day always rebuilds everything: today's window has moved, and MTD gains a day.
        return @{ mode='full'; cache=$parsed; reason="cache is as-of $asOf but today (Pacific) is $expectAsOf" }
    }
    if ($ageSec -ge $ttlSeconds) {
        return @{ mode='full'; cache=$parsed; reason=("MTD/YTD are {0:N0}s old (full TTL {1}s)" -f $ageSec, $ttlSeconds) }
    }

    # ---- step 5: MTD/YTD are fresh, so only today's much shorter clock is left ------------------
    # A cache written before today's period existed has no todayGeneratedAt at all; that is a
    # TODAY-ONLY rebuild, not a full one - the stored MTD/YTD are still perfectly good.
    if (-not $mToday.Success) {
        return @{ mode='today'; cache=$parsed
                  reason=("cache has no todayGeneratedAt (written before today's figure existed); MTD/YTD are still fresh at {0:N0}s of {1}s" -f $ageSec, $ttlSeconds) }
    }
    $tGen = $null
    try { $tGen = Parse-Utc $mToday.Groups[1].Value } catch { $tGen = $null }
    if ($null -eq $tGen) {
        return @{ mode='today'; cache=$parsed
                  reason="cache todayGeneratedAt '$($mToday.Groups[1].Value)' is unparseable" }
    }
    $tAgeSec = ([DateTime]::UtcNow - $tGen).TotalSeconds
    if ($tAgeSec -ge $todayTtlSeconds) {
        return @{ mode='today'; cache=$parsed
                  reason=("today's figure is {0:N0}s old (today TTL {1}s) while MTD/YTD are still fresh at {2:N0}s of {3}s - so only today needs rebuilding" -f $tAgeSec, $todayTtlSeconds, $ageSec, $ttlSeconds) }
    }

    # ---- step 6: both clocks fresh -------------------------------------------------------------
    @{ mode='skip'; cache=$parsed
       reason=("as-of $expectAsOf; today's figure is {0:N0}s old (TTL {1}s, {2:N0}s left) and MTD/YTD are {3:N0}s old (TTL {4}s, {5:N0}s left)" -f $tAgeSec, $todayTtlSeconds, ($todayTtlSeconds - $tAgeSec), $ageSec, $ttlSeconds, ($ttlSeconds - $ageSec)) }
}

if ($Force) {
    # -Force ignores BOTH clocks and always does the expensive full rebuild - the point of -Force is
    # "rebuild everything now", and a today-only forced run would be a surprising half-measure.
    $decision = @{ mode='full'; reason='-Force was passed'; cache=$null }
} else {
    $decision = Get-FlipRefreshDecision $file $todayStr $ttl $todayTtl $errCooldown
}

# -CheckOnly reports WHICH of the three outcomes and WHY, then stops. It makes NO network calls at
# all (config validation and file reads only), which is what makes the gate testable without
# spending minutes or any API quota - and it answers "why did/didn't it refresh?" in one second when
# something looks wrong.
if ($CheckOnly) {
    if ($decision.mode -eq 'full')      { Write-Host "CHECKONLY: would do a FULL recompute (all 3 periods, 6 report POSTs + ~42k-job pull, ~7-8 min) - $($decision.reason)" -ForegroundColor Cyan }
    elseif ($decision.mode -eq 'today') { Write-Host "CHECKONLY: would recompute TODAY ONLY (2 report POSTs + a one-day jobs pull, ~1-2 min; MTD/YTD carried forward) - $($decision.reason)" -ForegroundColor Cyan }
    else                                { Write-Host "CHECKONLY: would SKIP the recompute - $($decision.reason)" -ForegroundColor Green }
    exit 0
}

if ($decision.mode -eq 'skip') {
    Write-Host "Skipping the SILO flip recompute - $($decision.reason)"
    exit 0
}

# ---- recompute ------------------------------------------------------------------------------
if ($decision.mode -eq 'today') {
    Write-Host "Recomputing SILO flip (TODAY ONLY): $($decision.reason)"
    Write-Host ("[{0}] rebuilding today's figure as of {1} (2 report POSTs {2}s apart + a one-day jobs pull - expect ~1-2 min); MTD/YTD carried forward unchanged ..." -f (Get-Date).ToString('HH:mm:ss'), $todayStr, $cfg.postSpacingSeconds)
} else {
    Write-Host "Recomputing SILO flip (FULL): $($decision.reason)"
    Write-Host ("[{0}] building the full SILO flip snapshot as of {1} (6 report POSTs {2}s apart + a ~42k-job pull - expect ~7-8 min) ..." -f (Get-Date).ToString('HH:mm:ss'), $todayStr, $cfg.postSpacingSeconds)
}

$ctx  = New-StContext -SecretsPath $secretsPath
$snap = $null
if ($decision.mode -eq 'today') {
    # A today-only attempt that throws is recorded EXACTLY like a full failure: a status='error'
    # block, which puts the error on screen (never a stale number) and hands the retry to the
    # error-retry cooldown - which will then do a FULL rebuild.
    # THE COST IS DELIBERATE AND WORTH NAMING: writing the error block DISCARDS the healthy MTD/YTD
    # figures that were in the cache. That is the fail-loud choice (CLAUDE.md rule 1) - a tile that
    # silently keeps two of its three periods while one is broken reads as "fine", and the cooldown
    # rebuilds all three within the hour anyway.
    try { $snap = Build-SiloFlipTodaySnapshot $ctx $today $decision.cache }
    catch {
        Write-Host ("   TODAY-ONLY recompute FAILED: $($_.Exception.Message)") -ForegroundColor Red
        Write-Host ("   writing a status='error' block, exactly as a full failure does, so the error-retry cooldown ({0}s) now governs the retry and it will be a FULL rebuild. The stored MTD/YTD are discarded rather than shown next to a broken today." -f $errCooldown) -ForegroundColor Yellow
        $snap = New-SiloFlipErrorSnapshot $today ("today-only refresh failed: $($_.Exception.Message)")
    }
} else {
    $snap = Build-SiloFlipSnapshot $ctx $today
}
($snap | ConvertTo-Json -Depth 12) | Set-Content -Path $file -Encoding UTF8

$b = $snap.block
if ($b.status -ne 'ok') {
    Write-Host ("   wrote $file  (final=$($snap.final), status=ERROR: $($b.error))") -ForegroundColor Red
    return
}

Write-Host ("   wrote $file  (final=$($snap.final), status=ok, target=$($b.target)%)") -ForegroundColor Green
Write-Host ("   generatedAt (MTD/YTD) $($snap.generatedAt)   todayGeneratedAt $($snap.todayGeneratedAt)") -ForegroundColor DarkGray

# Print only the periods this run actually REBUILT. On a today-only run the MTD/YTD figures came
# straight out of the old cache, so re-printing them would imply they were just re-derived.
$printed = @('today','mtd','ytd')
if ($decision.mode -eq 'today') { $printed = @('today') }
foreach ($p in $printed) {
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
if ($decision.mode -eq 'today') {
    Write-Host ("   MTD/YTD carried forward unchanged from the {0} build: MTD {1}/{2}, YTD {3}/{4}" -f $snap.generatedAt, $b.periods['mtd'].num, $b.periods['mtd'].den, $b.periods['ytd'].num, $b.periods['ytd'].den) -ForegroundColor DarkGray
}
