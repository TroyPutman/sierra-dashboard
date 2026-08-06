# ============================================================================
#  refresh-silo.ps1  --  pull a month's SILO/ROPP snapshot to data/silo-<yyyy-MM>.json
#  The monthly analogue of refresh.ps1 (which does daily snapshots). Mirrors the daily
#  "recompute the current period, freeze past periods" policy:
#    * Default (no args): recompute the CURRENT Pacific month (written final=false, it is
#      still in progress and will keep changing), THEN finalize the PREVIOUS month if its
#      cache is missing or not yet final (freeze it once, final=true).
#    * -Month 2026-07 : recompute exactly that month (final is derived by Build-SiloSnapshot:
#      true when the month is strictly before the current Pacific month).
#
#  Why this exists: the static GitHub Pages build lists SILO months from whatever
#  data/silo-*.json files are present (build-static.ps1 -> manifest.siloMonths). Nothing
#  used to generate the CURRENT month, so the site was frozen to past committed months and
#  the month picker could never reach "this month". This script (run in the deploy workflow
#  before build-static, and available locally) keeps the current month present + fresh, the
#  same way refresh.ps1 keeps today's daily snapshot present + fresh.
#
#    .\refresh-silo.ps1                 # current month (live) + finalize previous if needed
#    .\refresh-silo.ps1 -Month 2026-07  # a specific month
#
#  FAILS LOUD: $ErrorActionPreference=Stop; any auth/API/build failure throws and the
#  caller (workflow step) fails the job. Uses the shared data + math layers; passes NO
#  pageSize=300 anywhere (Get-Metric-SiloRopp uses the safe default pager).
# ============================================================================
[CmdletBinding()]
param([string]$Month)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/metrics.ps1')

$dataDir = Join-Path $PSScriptRoot 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$secretsPath = Join-Path $PSScriptRoot 'secrets.json'

function Test-SiloFileFinal([string]$file) {
    if (-not (Test-Path $file)) { return $false }
    try { $p = Get-Content $file -Raw | ConvertFrom-Json } catch { return $false }
    return ($p.final -eq $true)
}

function Do-SiloRefresh([datetime]$monthFirst, [datetime]$curFirst) {
    $monthStr = $monthFirst.ToString('yyyy-MM')
    Write-Host ("[{0}] building SILO snapshot for {1} ..." -f (Get-Date).ToString('HH:mm:ss'), $monthStr)
    $ctx  = New-StContext -SecretsPath $secretsPath
    $snap = Build-SiloSnapshot $ctx $monthFirst $curFirst
    $file = Join-Path $dataDir ("silo-{0}.json" -f $monthStr)
    ($snap | ConvertTo-Json -Depth 12) | Set-Content -Path $file -Encoding UTF8
    $b = $snap.block
    if ($b.status -eq 'ok') {
        $footer = if ($b.tables -and $b.tables[0]) { $b.tables[0].footer } else { '' }
        Write-Host ("   wrote $file  (final=$($snap.final), status=ok)  $footer") -ForegroundColor Green
    } else {
        Write-Host ("   wrote $file  (final=$($snap.final), status=ERROR: $($b.error))") -ForegroundColor Red
    }
    return $snap
}

$pac      = Get-Pac
$today    = Get-TodayPac $pac
$curFirst = [datetime](Get-Date -Year $today.Year -Month $today.Month -Day 1)

if (-not [string]::IsNullOrWhiteSpace($Month)) {
    # Explicit single-month refresh.
    try { $mFirst = [DateTime]::ParseExact("$Month-01",'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture) }
    catch { throw "bad -Month '$Month' (expected yyyy-MM)" }
    Do-SiloRefresh $mFirst $curFirst | Out-Null
    return
}

# Default: recompute the CURRENT month (live, final=false) ...
Do-SiloRefresh $curFirst $curFirst | Out-Null

# ... then finalize the PREVIOUS month once, if it is missing or not yet frozen. This mirrors
# the deploy workflow's "finalize yesterday if needed" step for daily snapshots. A previous
# month already frozen (final=true) is left untouched -- past months never re-pull.
$prevFirst = $curFirst.AddMonths(-1)
$prevStr   = $prevFirst.ToString('yyyy-MM')
$prevFile  = Join-Path $dataDir ("silo-{0}.json" -f $prevStr)
if (Test-SiloFileFinal $prevFile) {
    Write-Host "Previous month ($prevStr) already final - skipping (past months are frozen)."
} else {
    Write-Host "Previous month ($prevStr) missing/not final - refreshing once to freeze it."
    Do-SiloRefresh $prevFirst $curFirst | Out-Null
}
