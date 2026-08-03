# ============================================================================
#  get-silo-ropp.ps1
#  SILO / ROPP monthly view - per-tech ROPP calls ran, TGLs generated, and
#  conversion, for the 14-tech SILO roster, for ONE month. Prints to screen.
#  No dashboard, no web page.
#
#  LOCKED DEFINITION (see SPEC.md M9):
#   - A ROPP CALL = a JOB that: carries the ROPP tag (tagTypeId 962027) AND is in
#     HVAC - Service (333) or HVAC - Maintenance (342817560) AND jobStatus=Completed
#     with completedOn in the month (Pacific) AND passes the new-opportunity filter
#     (recallForId empty, warrantyId empty, job-type name not recall|warranty|part.*install)
#     AND was RUN BY a roster tech (active appointment-assignment, matched by technician name).
#     Count every qualifying job (NO customer dedupe).
#   - A TGL = a JOB of an "Estimate ... TGL" job type, CREATED in the month, whose
#     jobGeneratedLeadSource.employeeId resolves to a roster tech (inactive employees included).
#   - CONVERSION = TGLs / calls, per tech and for the SILO total.
#   - "A month" = Pacific (America/Los_Angeles) calendar month -> UTC window. Never raw UTC.
#
#  MONTH BY MONTH by design: one month is far fewer API calls than a long window.
#  Fails loud: any API error / unresolved field STOPS with a message; never a guessed number.
#
#  Usage:
#    .\get-silo-ropp.ps1                 # defaults to LAST full month (Pacific)
#    .\get-silo-ropp.ps1 -Month 2026-06
# ============================================================================
[CmdletBinding()]
param([string]$Month)   # yyyy-MM ; omit = last full month

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib/st-common.ps1')

function Fail($m){ Write-Host "`nFAILED: $m`n" -ForegroundColor Red; exit 1 }

# --- SILO config (locked) ---
$ROPP_TAG   = '962027'
$CALL_BUS   = @('333','342817560')                     # HVAC Service + HVAC Maintenance
$EST_TGL_JOBTYPES = @(532267298,532269553,532279667,532275186,532275369,532272809,532279441)  # "Estimate ... TGL"
# 14-tech SILO roster (matched on assignment technicianName: last name + an accepted first name)
$ROSTER = @(
 @{disp='Noah Weng';last='weng';firsts=@('noah')},              @{disp='Joe Mendoza';last='mendoza';firsts=@('joe','joseph')},
 @{disp='Benjamin Wyllie';last='wyllie';firsts=@('benjamin','ben')}, @{disp='Nikko April';last='april';firsts=@('nikko')},
 @{disp='Andrew Trujillo';last='trujillo';firsts=@('andrew')},  @{disp='Dustin Romine';last='romine';firsts=@('dustin')},
 @{disp='Juan Tlatenchi';last='tlatenchi';firsts=@('juan')},    @{disp='Brandon Moreno';last='moreno';firsts=@('brandon')},
 @{disp='Francisco Valencia';last='valencia';firsts=@('francisco')}, @{disp='Mario Castro';last='castro';firsts=@('mario')},
 @{disp='Cole Pantol';last='pantol';firsts=@('cole')},          @{disp='Nathan Colquitt';last='colquitt';firsts=@('nathan')},
 @{disp='Robert Silinzy';last='silinzy';firsts=@('robert','rob')},   @{disp='Alex Yakovchuk';last='yakovchuk';firsts=@('alex','oleksiy')}
)
function Match-Roster($name){
  if([string]::IsNullOrWhiteSpace($name)){ return $null }
  $toks = [regex]::Matches($name.ToLower(),'[a-z]+') | ForEach-Object { $_.Value }
  foreach($r in $ROSTER){ if(($toks -contains $r.last) -and (@($toks | Where-Object { $r.firsts -contains $_ }).Count -gt 0)){ return $r.disp } }
  $null
}

# --- month window (Pacific -> UTC) ---
try {
  if([string]::IsNullOrWhiteSpace($Month)){
    $t = (Get-TodayPac (Get-Pac)); $first = (Get-Date -Year $t.Year -Month $t.Month -Day 1).AddMonths(-1)
  } else {
    $first = [DateTime]::ParseExact("$Month-01",'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture)
  }
} catch { Fail "bad -Month '$Month' (expected yyyy-MM)" }
$monthStr = $first.ToString('yyyy-MM')
$ctx = New-StContext -SecretsPath (Join-Path $PSScriptRoot 'secrets.json')
$pac = $ctx.Pac
$sUtc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($first,'Unspecified'),$pac)
$eUtc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($first.AddMonths(1),'Unspecified'),$pac)
$sIso = $sUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ"); $eIso = $eUtc.ToString("yyyy-MM-ddTHH:mm:ss.fffffffZ")
$sw = [Diagnostics.Stopwatch]::StartNew()
Write-Host "SILO / ROPP - $monthStr   (Pacific month; UTC $sIso .. $eIso)`n"

$jt = Get-JobTypeMap $ctx

# --- id -> name map (incl. INACTIVE) for TGL generating-tech resolution ---
$idName = @{}
foreach($q in @(@{}, @{active='false'})){
  foreach($e in (Invoke-StPaged $ctx "/settings/v2/tenant/$($ctx.Tenant)/technicians" $q)){ $idName["$($e.id)"] = $e.name }
  foreach($e in (Invoke-StPaged $ctx "/settings/v2/tenant/$($ctx.Tenant)/employees"   $q)){ if(-not $idName.ContainsKey("$($e.id)")){ $idName["$($e.id)"] = $e.name } }
}

# --- CALLS: ROPP + svc/maint + Completed + new-opp, attributed to roster by assignment tech name ---
$callsPerTech = @{}; foreach($r in $ROSTER){ $callsPerTech[$r.disp] = 0 }
$ropp = Invoke-StPaged $ctx "/jpm/v2/tenant/$($ctx.Tenant)/jobs" @{ tagTypeIds=$ROPP_TAG; jobStatus='Completed'; completedOnOrAfter=$sIso; completedBefore=$eIso }
$callJobs = @($ropp | Where-Object { ("$($_.businessUnitId)" -in $CALL_BUS) -and (Test-NewOpportunity $_ $jt) })
$siloCallJobs = New-Object 'System.Collections.Generic.HashSet[string]'
$noAssign = 0
foreach($j in $callJobs){
  $as = Invoke-RestMethod -Method Get -Uri "$script:ApiBase/dispatch/v2/tenant/$($ctx.Tenant)/appointment-assignments?jobId=$($j.id)&pageSize=50&page=1" -Headers $ctx.Headers
  $names = @($as.data | Where-Object { $_.active } | ForEach-Object { $_.technicianName })
  if($names.Count -eq 0){ $noAssign++ }
  $seen = @{}
  foreach($n in $names){ $d = Match-Roster $n; if($d -and -not $seen.ContainsKey($d)){ $callsPerTech[$d]++; $seen[$d]=$true; [void]$siloCallJobs.Add("$($j.id)") } }
}

# --- TGLs: Estimate-TGL created in month, attributed via jobGeneratedLeadSource.employeeId ---
$tglPerTech = @{}; foreach($r in $ROSTER){ $tglPerTech[$r.disp] = 0 }
$estTotal = 0; $glsMissing = 0; $idUnresolved = 0
foreach($tid in $EST_TGL_JOBTYPES){
  foreach($j in (Invoke-StPaged $ctx "/jpm/v2/tenant/$($ctx.Tenant)/jobs" @{ jobTypeId=$tid; createdOnOrAfter=$sIso; createdBefore=$eIso })){
    $estTotal++
    $g = $j.jobGeneratedLeadSource
    if(-not $g -or (Is-EmptyVal $g.employeeId)){ $glsMissing++; continue }
    $nm = if($idName.ContainsKey("$($g.employeeId)")){ $idName["$($g.employeeId)"] } else { $idUnresolved++; $null }
    $d = Match-Roster $nm
    if($d){ $tglPerTech[$d]++ }
  }
}

# --- output ---
$totC=0; $totT=0
Write-Host ("{0,-20} {1,7} {2,7} {3,9}" -f 'Technician','Calls','TGLs','Conv')
Write-Host ("-"*45)
foreach($r in $ROSTER){
  $c=$callsPerTech[$r.disp]; $t=$tglPerTech[$r.disp]; $totC+=$c; $totT+=$t
  $conv = if($c -gt 0){ "{0:N1}%" -f (100.0*$t/$c) } else { '-' }
  Write-Host ("{0,-20} {1,7} {2,7} {3,9}" -f $r.disp,$c,$t,$conv)
}
Write-Host ("-"*45)
$siloConv = if($totC -gt 0){ "{0:N1}%" -f (100.0*$totT/$totC) } else { '-' }
Write-Host ("{0,-20} {1,7} {2,7} {3,9}" -f 'SILO TOTAL',$totC,$totT,$siloConv)
Write-Host ("  (distinct call jobs attributed to SILO: {0})" -f $siloCallJobs.Count)
Write-Host ""
Write-Host ("calls: {0} ROPP svc+maint new-opp completed jobs examined; {1} had no active assignment" -f $callJobs.Count,$noAssign)
Write-Host ("TGLs : {0} Estimate-TGL jobs created; {1} missing jobGeneratedLeadSource; {2} employeeIds unresolved" -f $estTotal,$glsMissing,$idUnresolved)
$sw.Stop()
Write-Host ("elapsed: {0}s" -f [int]$sw.Elapsed.TotalSeconds)
