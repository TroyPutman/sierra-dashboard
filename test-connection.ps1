# ============================================================================
#  test-connection.ps1
#  Purpose: Prove that our ServiceTitan API credentials work. Nothing else.
#
#  What it does, in plain English:
#    1. Reads our credentials out of secrets.json (never hard-coded here).
#    2. Asks ServiceTitan's login server for an access token.
#    3. Makes ONE small read-only call (grabs a single technician record).
#    4. Tells you: did we get a token? what HTTP status came back? and shows
#       the first record it found.
#
#  Rules it follows:
#    - It NEVER prints your clientId, clientSecret, appKey, or the token.
#    - If anything fails, it STOPS and prints the exact error + status code.
#      It never fakes a result and never silently retries.
#
#  How to run it (later — do NOT run yet):
#    Open PowerShell in this folder and type:  .\test-connection.ps1
# ============================================================================

# Stop the whole script the moment anything throws an error. (Fail loud.)
$ErrorActionPreference = 'Stop'

# Older Windows PowerShell sometimes defaults to an old, blocked TLS version.
# This line makes sure we use TLS 1.2, which ServiceTitan requires.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ServiceTitan's fixed addresses (confirmed from their developer docs):
$TokenUrl = 'https://auth.servicetitan.io/connect/token'   # where we get the token
$ApiBase  = 'https://api.servicetitan.io'                   # where we make API calls

# A small helper so we can stop with a clear, loud message anywhere.
function Stop-Loud($message) {
    Write-Host ""
    Write-Host "FAILED: $message" -ForegroundColor Red
    Write-Host ""
    exit 1
}

# ----------------------------------------------------------------------------
# STEP 1 — Read the credentials from secrets.json
# ----------------------------------------------------------------------------
$secretsPath = Join-Path $PSScriptRoot 'secrets.json'

if (-not (Test-Path $secretsPath)) {
    Stop-Loud "Can't find secrets.json in this folder. Copy secrets.example.json to secrets.json and fill in the real values."
}

try {
    $secrets = Get-Content $secretsPath -Raw | ConvertFrom-Json
} catch {
    Stop-Loud "secrets.json exists but isn't valid JSON. Fix the file. Details: $($_.Exception.Message)"
}

# Make sure every field we need is actually filled in.
foreach ($field in 'clientId','clientSecret','appKey','tenantId') {
    if ([string]::IsNullOrWhiteSpace($secrets.$field)) {
        Stop-Loud "secrets.json is missing a value for '$field'. Fill it in and try again."
    }
}

# ----------------------------------------------------------------------------
# STEP 2 — Get an OAuth access token
# ----------------------------------------------------------------------------
Write-Host "Requesting access token from ServiceTitan..." -ForegroundColor Cyan

# The token request wants form fields, not JSON. PowerShell URL-encodes these
# values automatically, so special characters in the secret are handled safely.
$tokenBody = @{
    grant_type    = 'client_credentials'
    client_id     = $secrets.clientId
    client_secret = $secrets.clientSecret
}

$accessToken = $null
try {
    $tokenResponse = Invoke-RestMethod -Method Post -Uri $TokenUrl `
        -ContentType 'application/x-www-form-urlencoded' -Body $tokenBody
    $accessToken = $tokenResponse.access_token
} catch {
    # Pull the HTTP status code out of the failure, if there is one.
    $status = $null
    if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
    Stop-Loud "Token request failed. HTTP status: $status. Message: $($_.Exception.Message)"
}

if ([string]::IsNullOrWhiteSpace($accessToken)) {
    Stop-Loud "ServiceTitan responded but did not include an access token."
}

# Note: we say YES/NO only. We deliberately never print the token itself.
Write-Host "Token obtained: yes" -ForegroundColor Green

# ----------------------------------------------------------------------------
# STEP 3 — Make ONE small read-only API call
#   Endpoint: list technicians, but ask for only 1 record (pageSize=1).
#   Technicians live under the 'settings' namespace in the ServiceTitan API.
# ----------------------------------------------------------------------------
$apiUrl = "$ApiBase/settings/v2/tenant/$($secrets.tenantId)/technicians?page=1&pageSize=1"

Write-Host "Making test API call (technicians, 1 record)..." -ForegroundColor Cyan

$headers = @{
    'Authorization' = "Bearer $accessToken"
    'ST-App-Key'    = $secrets.appKey
}

try {
    # Use Invoke-WebRequest here so we can read the exact HTTP status code.
    $apiResponse = Invoke-WebRequest -Method Get -Uri $apiUrl -Headers $headers -UseBasicParsing
} catch {
    $status = $null
    $errorBody = $null
    if ($_.Exception.Response) {
        $status = [int]$_.Exception.Response.StatusCode
        try {
            $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
            $errorBody = $reader.ReadToEnd()
        } catch { }
    }
    Stop-Loud "API call failed. HTTP status: $status. Response body: $errorBody"
}

$statusCode = [int]$apiResponse.StatusCode

# Anything other than 200 is a failure. Stop loud.
if ($statusCode -ne 200) {
    Stop-Loud "API call returned HTTP $statusCode (expected 200). Body: $($apiResponse.Content)"
}

Write-Host "API call HTTP status: $statusCode" -ForegroundColor Green

# ----------------------------------------------------------------------------
# STEP 4 — Show the first record, readably
# ----------------------------------------------------------------------------
$data = $apiResponse.Content | ConvertFrom-Json

Write-Host ""
Write-Host "Total technicians reported by ServiceTitan: $($data.totalCount)"
Write-Host "First record returned:" -ForegroundColor Cyan

if ($data.data -and $data.data.Count -ge 1) {
    # Depth 5 makes nested fields print nicely instead of as 'System.Object'.
    $data.data[0] | ConvertTo-Json -Depth 5
} else {
    Write-Host "(The call succeeded but returned zero records.)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "SUCCESS: credentials work end-to-end." -ForegroundColor Green
