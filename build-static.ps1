# ============================================================================
#  build-static.ps1  --  STATIC SITE BUILDER (presentation layer, build-time only)
#  Produces a self-contained static build of the dashboard (for GitHub Pages / any static
#  host) from dashboard.html + the cached data/*.json snapshots. Does NOT touch serve.ps1,
#  which keeps working unchanged for local/live use.
#
#  Interface (depended on by other workstreams -- keep stable):
#    -OutDir <path>        default 'site'
#    -PasswordHash <hex>   optional; overrides $env:DASH_PASSWORD_HASH for local testing
#    -NoGate               skip the client-side password gate entirely (no hash required).
#                          Use ONLY when the deployment target is protected by an external
#                          auth layer at the edge (e.g. Cloudflare Access) -- the client-side
#                          gate would be redundant there. Default (no -NoGate) is unchanged:
#                          still requires a hash and still injects the gate.
#    env: DASH_PASSWORD_HASH  SHA-256 hex digest of the shared dashboard password
#
#  FAILS LOUD: throws (and writes nothing) if no password hash is available from either
#  source -- we must never publish an ungated static build. (Bypassed only when -NoGate is
#  passed, since in that mode gating is handled outside this script.)
#
#  Cross-platform: runs on Windows (local) and Linux (CI). Must not hard-depend on the
#  Windows-only 'Pacific Standard Time' timezone id; falls back to the IANA
#  'America/Los_Angeles' id (see Get-PacTz below).
# ============================================================================
[CmdletBinding()]
param(
    [string]$OutDir = 'site',
    [string]$PasswordHash,
    [switch]$NoGate
)

$ErrorActionPreference = 'Stop'

# ---- password hash: required unless -NoGate, fail loud, never produce an ungated build
#      (-NoGate is for deployments sitting behind an external auth layer at the edge, e.g.
#      Cloudflare Access, where the client-side gate would be redundant) ----
$hash = $null
if (-not $NoGate) {
    $hash = $PasswordHash
    if ([string]::IsNullOrWhiteSpace($hash)) { $hash = $env:DASH_PASSWORD_HASH }
    if ([string]::IsNullOrWhiteSpace($hash)) {
        throw "No password hash provided. Set `$env:DASH_PASSWORD_HASH or pass -PasswordHash. Refusing to build an unprotected static site. (Pass -NoGate if this build is protected by an external auth layer instead.)"
    }
    $hash = $hash.Trim().ToLowerInvariant()
    if ($hash -notmatch '^[0-9a-f]{64}$') {
        throw "Password hash must be a 64-char lowercase hex SHA-256 digest; got: '$hash'"
    }
}

# ---- Pacific timezone helper: try the Windows id first (matches lib/st-common.ps1's
#      Get-Pac convention), fall back to the IANA id so this also runs on Linux CI. This is
#      a LOCAL fallback, not a change to the shared Get-Pac helper in lib/st-common.ps1. ----
function Get-PacTz {
    try { [TimeZoneInfo]::FindSystemTimeZoneById('Pacific Standard Time') }
    catch { [TimeZoneInfo]::FindSystemTimeZoneById('America/Los_Angeles') }
}
function Format-Pac([datetime]$utc, $pac) {
    ([TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::SpecifyKind($utc, 'Utc'), $pac)).ToString('yyyy-MM-dd HH:mm')
}

$root        = $PSScriptRoot
$dashPath    = Join-Path $root 'dashboard.html'
$dataDir     = Join-Path $root 'data'
$outDirFull  = if ([System.IO.Path]::IsPathRooted($OutDir)) { $OutDir } else { Join-Path $root $OutDir }
$outDataDir  = Join-Path $outDirFull 'data'

if (-not (Test-Path $dashPath)) { throw "dashboard.html not found at $dashPath" }
if (-not (Test-Path $dataDir))  { throw "data/ directory not found at $dataDir" }

$pac    = Get-PacTz
$nowUtc = [DateTime]::UtcNow

# ---- collect available snapshots from data/ (cache files ARE byte-identical to the live
#      API responses -- see task background) ----
$dateFiles = Get-ChildItem -Path $dataDir -Filter '*.json' | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}\.json$' }
$siloFiles = Get-ChildItem -Path $dataDir -Filter 'silo-*.json' | Where-Object { $_.Name -match '^silo-\d{4}-\d{2}\.json$' }

$dates = @($dateFiles | ForEach-Object { $_.BaseName } | Sort-Object)
$siloMonths = @($siloFiles | ForEach-Object { $_.BaseName -replace '^silo-', '' } | Sort-Object)

if ($dates.Count -eq 0) { throw "no date snapshots (data/yyyy-MM-dd.json) found under $dataDir -- nothing to build" }

# ---- prepare output dir (never delete anything; just (re)create the build output) ----
if (-not (Test-Path $outDirFull)) { New-Item -ItemType Directory -Path $outDirFull -Force | Out-Null }
if (-not (Test-Path $outDataDir)) { New-Item -ItemType Directory -Path $outDataDir -Force | Out-Null }

# ---- copy every data/*.json (date snapshots + silo-*.json) into OutDir/data ----
Get-ChildItem -Path $dataDir -Filter '*.json' | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $outDataDir $_.Name) -Force
}

# ---- manifest.json ----
$manifest = [ordered]@{
    generatedAt    = $nowUtc.ToString('o')
    generatedAtPac = Format-Pac $nowUtc $pac
    dates          = $dates
    siloMonths     = $siloMonths
}
($manifest | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $outDirFull 'manifest.json') -Encoding UTF8

# ---- freshness.json (drives the header "Data as of ..." stamp in STATIC_MODE) ----
$latestDate = $dates[$dates.Count - 1]
$latestFile = Join-Path $dataDir "$latestDate.json"
$todayPulledAtPac = $null
if (Test-Path $latestFile) {
    $todayPulledAtPac = Format-Pac (Get-Item $latestFile).LastWriteTimeUtc $pac
}
$freshness = [ordered]@{
    generatedAt    = $nowUtc.ToString('o')
    generatedAtPac = Format-Pac $nowUtc $pac
    latestDate     = $latestDate
    todayPulledAt  = $todayPulledAtPac
}
($freshness | ConvertTo-Json -Depth 5) | Set-Content -Path (Join-Path $outDirFull 'freshness.json') -Encoding UTF8

# ---- build index.html: inject STATIC_MODE flag (+ password gate, unless -NoGate) into a
#      copy of dashboard.html ----
$html = Get-Content -Path $dashPath -Raw

$staticFlagScript = "<script>window.__DASH_STATIC__=true;</script>`n"

$gateHtml = @'
<style>
  #dashGate{position:fixed; inset:0; z-index:9999; display:flex; align-items:center; justify-content:center;
    background:#ffffff; font-family:'Poppins',"Segoe UI Variable Display","Segoe UI",system-ui,Roboto,Arial,sans-serif;}
  #dashGate.hidden{display:none;}
  #dashGate .card{background:#f2f6fb; border:1px solid #d4deea; border-radius:18px; padding:36px 40px;
    width:min(360px,90vw); box-shadow:0 4px 18px rgba(8,66,122,.12); text-align:center;}
  #dashGate .card h1{font-size:1.2rem; font-weight:700; color:#08427a; margin-bottom:6px;}
  #dashGate .card p{font-size:.85rem; color:#5c6b80; margin-bottom:18px;}
  #dashGate input[type=password]{width:100%; padding:10px 12px; font-size:1rem; border:1px solid #d4deea;
    border-radius:9px; margin-bottom:12px; box-sizing:border-box;}
  #dashGate button{width:100%; padding:10px 12px; font-size:1rem; font-weight:600; color:#fff;
    background:#0a66b0; border:none; border-radius:9px; cursor:pointer;}
  #dashGate button:hover{background:#08427a;}
  #dashGate .err{color:#c42b28; font-size:.82rem; margin-top:10px; min-height:1.1em;}
</style>
<div id="dashGate">
  <div class="card">
    <h1>Sierra Morning Dashboard</h1>
    <p>Enter the shared password to continue.</p>
    <input type="password" id="dashGatePw" autocomplete="current-password" placeholder="Password">
    <button id="dashGateBtn" type="button">Unlock</button>
    <div class="err" id="dashGateErr"></div>
  </div>
</div>
<script>
(function(){
  var EXPECTED_HASH = "__DASH_PASSWORD_HASH__";
  var gate = document.getElementById('dashGate');
  var errEl = document.getElementById('dashGateErr');
  function unlock(){ gate.classList.add('hidden'); }
  try {
    if (window.localStorage && localStorage.getItem('dash_ok') === '1') { unlock(); return; }
  } catch(e) {}
  async function sha256Hex(text){
    var enc = new TextEncoder().encode(text);
    var buf = await crypto.subtle.digest('SHA-256', enc);
    var bytes = new Uint8Array(buf);
    var hex = '';
    for (var i=0;i<bytes.length;i++){ hex += bytes[i].toString(16).padStart(2,'0'); }
    return hex;
  }
  async function tryUnlock(){
    var pw = document.getElementById('dashGatePw').value || '';
    var h = await sha256Hex(pw);
    if (h === EXPECTED_HASH) {
      try { localStorage.setItem('dash_ok','1'); } catch(e) {}
      errEl.textContent = '';
      unlock();
    } else {
      errEl.textContent = 'Incorrect password.';
    }
  }
  document.getElementById('dashGateBtn').addEventListener('click', tryUnlock);
  document.getElementById('dashGatePw').addEventListener('keydown', function(e){ if (e.key === 'Enter') tryUnlock(); });
})();
</script>
'@

if (-not $NoGate) {
    $gateHtml = $gateHtml.Replace('__DASH_PASSWORD_HASH__', $hash)
}

if ($html -notmatch '<script>') { throw "dashboard.html has no <script> tag -- cannot inject STATIC_MODE" }
# Inject the static-mode flag immediately before the FIRST <script> tag (the main app script).
# Must happen BEFORE the gate is inserted, since the gate adds its own earlier <script> tag.
$idx = $html.IndexOf('<script>')
$html = $html.Substring(0, $idx) + $staticFlagScript + $html.Substring($idx)

if (-not $NoGate) {
    if ($html -notmatch '<body>') { throw "dashboard.html has no <body> tag -- cannot inject the password gate" }
    $html = $html -replace '<body>', ("<body>`n" + $gateHtml)
}

Set-Content -Path (Join-Path $outDirFull 'index.html') -Value $html -Encoding UTF8

Write-Host "Static site built at $outDirFull" -ForegroundColor Green
Write-Host ("  dates: {0}  ({1} .. {2})" -f $dates.Count, $dates[0], $latestDate) -ForegroundColor Cyan
Write-Host ("  silo months: {0}" -f ($siloMonths -join ', ')) -ForegroundColor Cyan
