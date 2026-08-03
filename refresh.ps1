# ============================================================================
#  refresh.ps1  --  pull a date's snapshot to data/<date>.json
#  Uses the data + math layers. Run to pre-warm a day, or -Loop to keep today live.
#    .\refresh.ps1                      # today
#    .\refresh.ps1 -Date 2026-07-15     # a specific Pacific day
#    .\refresh.ps1 -Loop -Every 180     # recompute today every 180s (for the live wall)
# ============================================================================
[CmdletBinding()]
param([string]$Date, [switch]$Loop, [int]$Every = 180)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/metrics.ps1')

$dataDir = Join-Path $PSScriptRoot 'data'
if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir | Out-Null }
$secretsPath = Join-Path $PSScriptRoot 'secrets.json'

function Do-Refresh([string]$dateStr) {
    $pac = Get-Pac
    $today = Get-TodayPac $pac
    if ([string]::IsNullOrWhiteSpace($dateStr)) { $d = $today }
    else { $d = [DateTime]::ParseExact($dateStr, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
    Write-Host ("[{0}] pulling snapshot for {1} ..." -f (Get-Date).ToString('HH:mm:ss'), $d.ToString('yyyy-MM-dd'))
    $ctx = New-StContext -SecretsPath $secretsPath
    $snap = Build-Snapshot $ctx $d $today
    $file = Join-Path $dataDir ("{0}.json" -f $d.ToString('yyyy-MM-dd'))
    ($snap | ConvertTo-Json -Depth 12) | Set-Content -Path $file -Encoding UTF8
    $ok = @($snap.metrics | Where-Object { $_.status -eq 'ok' }).Count
    $err = @($snap.metrics | Where-Object { $_.status -eq 'error' }).Count
    Write-Host ("   wrote $file  ($ok ok, $err error)") -ForegroundColor Green
    foreach ($m in ($snap.metrics | Where-Object { $_.status -eq 'error' })) { Write-Host ("   ERROR $($m.id): $($m.error)") -ForegroundColor Red }
}

if ($Loop) {
    Write-Host "Live loop: recomputing today every $Every seconds. Ctrl+C to stop." -ForegroundColor Cyan
    while ($true) {
        try { Do-Refresh $null } catch { Write-Host "refresh failed: $($_.Exception.Message)" -ForegroundColor Red }
        Start-Sleep -Seconds $Every
    }
} else {
    Do-Refresh $Date
}
