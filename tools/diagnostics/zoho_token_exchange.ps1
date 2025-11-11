<#
Exchange a Zoho OAuth authorization code for an access token.
USAGE:
  .\zoho_token_exchange.ps1 -ClientId "1000.xxx" -ClientSecret "xxxx" -Code "1000.xxxx" -RedirectUri "https://your-app/callback" [-AccountsDomain com]

Notes:
- AccountsDomain is the suffix for accounts host: com, eu, in, jp, au, etc. Default: com
- Prints access_token and a ready-to-copy PowerShell line to set $env:ZB_TOKEN
#>
param(
  [Parameter(Mandatory=$true)][string]$ClientId,
  [Parameter(Mandatory=$true)][string]$ClientSecret,
  [Parameter(Mandatory=$true)][string]$Code,
  [Parameter()][string]$RedirectUri,  # Optional for Zoho Books Self Client
  [Parameter()][string]$AccountsDomain = "com"
)
$ErrorActionPreference = "Stop"
$tokenUrl = "https://accounts.zoho.$AccountsDomain/oauth/v2/token"
$body = @{
  grant_type    = "authorization_code"
  client_id     = $ClientId
  client_secret = $ClientSecret
  code          = $Code
}
if ($RedirectUri -and $RedirectUri.Trim() -ne "") {
  $body.redirect_uri = $RedirectUri.Trim()
}
Write-Host "POST $tokenUrl" -ForegroundColor Cyan
try {
  $resp = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $body -ContentType "application/x-www-form-urlencoded"
} catch {
  Write-Error "Token exchange failed: $($_.Exception.Message)"; throw
}
if ($null -eq $resp) { Write-Error "Empty response"; exit 1 }
$access = $resp.access_token
$refresh = $resp.refresh_token
$expires = $resp.expires_in
function Mask-Token([string]$t) { if([string]::IsNullOrEmpty($t)){ return $t }; if($t.Length -le 12){ return $t }; return $t.Substring(0,6) + '...' + $t.Substring($t.Length-6) }
Write-Host ("access_token: " + (Mask-Token $access)) -ForegroundColor Green
if ($refresh) { Write-Host ("refresh_token: " + (Mask-Token $refresh)) -ForegroundColor Yellow }
Write-Host "expires_in: $expires" -ForegroundColor Magenta
if ($access) {
  $env:ZB_TOKEN = "Zoho-oauthtoken $access"
  Write-Host ("Environment variable ZB_TOKEN set (len=" + $access.Length + ")") -ForegroundColor Cyan
}
Write-Host "";
Write-Host "Set env for diagnostics (PowerShell):" -ForegroundColor Cyan
Write-Host ('$env:ZB_TOKEN = "Zoho-oauthtoken ' + $access + '"')
