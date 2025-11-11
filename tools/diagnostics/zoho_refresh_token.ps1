<#!
Refresh a Zoho OAuth refresh token to obtain a new access token.
USAGE:
  pwsh ./zoho_refresh_token.ps1 -ClientId "1000.xxx" -ClientSecret "xxxx" -RefreshToken "1000.xxxx" [-AccountsDomain com]

Notes:
- Provides a new access token; original refresh token normally remains valid.
- Scopes tied to the refresh token from original grant.
- Prints masked tokens and a ready-to-copy line to set $env:ZANALYTICS_TOKEN or generic token var.
!>
param(
  [Parameter(Mandatory=$true)][string]$ClientId,
  [Parameter(Mandatory=$true)][string]$ClientSecret,
  [Parameter(Mandatory=$true)][string]$RefreshToken,
  [Parameter()][string]$AccountsDomain = "com"
)
$ErrorActionPreference = 'Stop'
$tokenUrl = "https://accounts.zoho.$AccountsDomain/oauth/v2/token"
$body = @{
  grant_type    = 'refresh_token'
  client_id     = $ClientId
  client_secret = $ClientSecret
  refresh_token = $RefreshToken
}
Write-Host "POST $tokenUrl" -ForegroundColor Cyan
try {
  $resp = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $body -ContentType 'application/x-www-form-urlencoded'
} catch {
  Write-Error "Refresh failed: $($_.Exception.Message)"; throw
}
if ($null -eq $resp) { Write-Error 'Empty response'; exit 1 }
$access = $resp.access_token
$expires = $resp.expires_in
function Mask([string]$t){ if([string]::IsNullOrEmpty($t)){return $t}; if($t.Length -le 12){return $t}; return $t.Substring(0,6)+'...'+$t.Substring($t.Length-6) }
Write-Host ("access_token: " + (Mask $access)) -ForegroundColor Green
Write-Host "expires_in: $expires" -ForegroundColor Magenta
if ($access) {
  $env:ZANALYTICS_TOKEN = $access
  Write-Host "Environment variable ZANALYTICS_TOKEN set (len=$($access.Length))" -ForegroundColor Cyan
  Write-Host "To use with export-schema.ps1:" -ForegroundColor Cyan
  Write-Host ('$env:ZOHO_ANALYTICS_TOKEN = "'+$access+'"')
}
