<#
Create or update Zoho Analytics Query Tables from a JSON config using the Analytics API.
Requires env vars:
  ZOHO_ANALYTICS_DOMAIN (e.g., https://analyticsapi.zoho.com)
  ZOHO_ANALYTICS_WORKSPACE (internal workspace ID)
  ZOHO_ANALYTICS_ORGID (if required)
  ZOHO_ANALYTICS_TOKEN (access token, raw)
Scopes needed: ZohoAnalytics.metadata.read, ZohoAnalytics.metadata.create, ZohoAnalytics.data.read
#>
param(
  [Parameter(Mandatory=$true)][string]$ConfigPath = "./query-tables.json"
)
$ErrorActionPreference = 'Stop'
$domain = $env:ZOHO_ANALYTICS_DOMAIN
$ws = $env:ZOHO_ANALYTICS_WORKSPACE
$org = $env:ZOHO_ANALYTICS_ORGID
$token = $env:ZOHO_ANALYTICS_TOKEN
if(-not $domain){ throw "Set ZOHO_ANALYTICS_DOMAIN" }
if(-not $ws){ throw "Set ZOHO_ANALYTICS_WORKSPACE" }
if(-not $token){ throw "Set ZOHO_ANALYTICS_TOKEN" }
$headers = @{ Authorization = "Zoho-oauthtoken $token" }
if($org){ $headers['ZANALYTICS-ORGID'] = $org }
if(-not (Test-Path -LiteralPath $ConfigPath)){ throw "Config not found: $ConfigPath" }
$cfg = Get-Content -Raw -LiteralPath $ConfigPath | ConvertFrom-Json

function Invoke-AnalyticsJson([string]$Method,[string]$Url,$Body){
  try{
    if($Body){ $json = $Body | ConvertTo-Json -Depth 10 }
    if($Method -eq 'GET'){
      return Invoke-RestMethod -Method GET -Headers $headers -Uri $Url -TimeoutSec 60
    } else {
      return Invoke-RestMethod -Method $Method -Headers $headers -Uri $Url -TimeoutSec 60 -ContentType 'application/json' -Body $json
    }
  } catch {
    Write-Error "$Method $Url failed: $($_.Exception.Message)"; if($_.ErrorDetails.Message){ Write-Host $_.ErrorDetails.Message }; throw
  }
}

$base = "$domain/restapi/v2/workspaces/$ws"

# Ensure workspace reachable
Write-Host "Workspace: $ws" -ForegroundColor Cyan
try { Invoke-AnalyticsJson GET "$domain/restapi/v2/workspaces?action=LIST" | Out-Null } catch { Write-Warning "Workspace list failed (token/region), continuing..." }

# Sort by dependency order
$ordered = @()
$pending = @($cfg)
while($pending.Count -gt 0){
  $progress = $false
  foreach($t in @($pending)){
    $deps = @($t.dependsOn)
    if($deps.Count -eq 0 -or ($deps | Where-Object { $_ -in $ordered.name }).Count -eq $deps.Count){
      $ordered += $t; $pending = $pending | Where-Object { $_.name -ne $t.name }; $progress=$true
    }
  }
  if(-not $progress){ throw "Cyclic or missing dependency names in config." }
}

foreach($t in $ordered){
  $name = $t.name
  $sql = $t.sql
  Write-Host "Creating query table: $name" -ForegroundColor Green
  # Build CONFIG payload as per API spec
  $config = @{ queryTableName = $name; sqlQuery = $sql }
  if($t.description){ $config.description = $t.description }
  if($t.folderId){ $config.folderId = $t.folderId }
  $configJson = ($config | ConvertTo-Json -Depth 10 -Compress)
  $form = @{ CONFIG = $configJson }
  $createUrl = "$base/querytables?action=CREATE"
  try {
    Invoke-RestMethod -Method POST -Headers $headers -Uri $createUrl -ContentType 'application/x-www-form-urlencoded' -Body $form | Out-Null
    Write-Host "Created: $name" -ForegroundColor Green
  } catch {
    $err = $_.ErrorDetails.Message
    if($err -and $err -match 'already exists|7409'){ # Already exists textual or code
      Write-Warning "Query table '$name' already exists. Skipping create."
    } else {
      Write-Error "Failed to create query table '$name': $($_.Exception.Message)"; if($err){ Write-Host $err }; throw
    }
  }
  # Scheduling will be handled in a later step once view IDs are confirmed via listing endpoints
}

Write-Host "All query tables processed." -ForegroundColor Green
