Param(
  [string]$Domain = $env:ZOHO_ANALYTICS_DOMAIN,          # e.g. https://analytics.zoho.com
  [string]$WorkspaceId = $env:ZOHO_ANALYTICS_WORKSPACE,   # e.g. 1234567890123456789
  [string]$AccessToken = $env:ZOHO_ANALYTICS_TOKEN,       # Raw access token (without Zoho-oauthtoken prefix)
  [string]$OrgId = $env:ZOHO_ANALYTICS_ORGID,             # Optional: Zoho Analytics Org ID (required in some tenants)
  [string]$OutFile = "DATA_SCHEMA.out.json"
)

$ErrorActionPreference = 'Stop'
if (-not $Domain) { throw "Set -Domain or ZOHO_ANALYTICS_DOMAIN (e.g., https://analytics.zoho.com)" }
if (-not $WorkspaceId) { throw "Set -WorkspaceId or ZOHO_ANALYTICS_WORKSPACE" }
# Fallback: derive raw token from ZB_TOKEN if analytics token not explicitly set
if (-not $AccessToken -and $env:ZB_TOKEN) {
  $AccessToken = ($env:ZB_TOKEN -replace '^Zoho-oauthtoken\s*','')
}
if (-not $AccessToken) { throw "Set -AccessToken or ZOHO_ANALYTICS_TOKEN (Zoho OAuth access token)" }

# Prepare headers early for all requests (including connectivity test)
$Headers = @{ Authorization = "Zoho-oauthtoken $AccessToken"; Accept = 'application/json' }
if ($OrgId -and $OrgId.Trim() -ne "") {
  # Some Analytics APIs require the Org ID header
  $Headers["ZANALYTICS-ORGID"] = $OrgId.Trim()
}

Write-Host "Domain: $Domain" -ForegroundColor Cyan
Write-Host "Workspace: $WorkspaceId" -ForegroundColor Cyan
if ($OrgId) { Write-Host "OrgId: $OrgId" -ForegroundColor Cyan }
Write-Host ("Token length: {0}" -f $AccessToken.Length) -ForegroundColor DarkGray
Write-Host "Testing connectivity..." -ForegroundColor Yellow

try {
  $pingUrl = "$Domain/restapi/v2/workspaces?action=LIST"
  $pingResp = Invoke-RestMethod -Method GET -Headers $Headers -Uri $pingUrl -TimeoutSec 30 -ErrorAction Stop
  Write-Host "Connectivity OK (workspace list retrieved)." -ForegroundColor Green
  $ws = $pingResp.workspaces; if (-not $ws) { $ws = $pingResp.data }
  if ($ws) {
    Write-Host ("Found {0} workspaces:" -f $ws.Count) -ForegroundColor Yellow
    foreach ($w in $ws) {
      $wid = $w.id
      $wname = $w.name
      if (-not $wname) { $wname = $w.displayName }
      Write-Host (" - id={0}  name={1}" -f $wid, $wname)
    }
    if ($WorkspaceId -and ($ws | Where-Object { $_.id -eq $WorkspaceId } | Measure-Object).Count -eq 0) {
      Write-Warning "Provided WorkspaceId not found in list above. Verify the ID or use one of the listed IDs."
    }
  }
} catch {
  Write-Warning "Workspace list request failed; verify domain/token/region. $_" 
}

## Headers already prepared above

function Get-Json($Url) {
  try {
    Invoke-RestMethod -Method GET -Headers $Headers -Uri $Url -TimeoutSec 60
  } catch {
    Write-Error "GET $Url failed: $($_.Exception.Message)"; 
    if ($_.Exception.Response) {
      $status = $_.Exception.Response.StatusCode.value__
      if ($status -eq 400) {
        if (-not $OrgId) { Write-Warning "HTTP 400. If your tenant requires an Org ID, set -OrgId / ZOHO_ANALYTICS_ORGID." }
        Write-Warning "400 could also indicate: invalid workspace id, insufficient scopes, or unsupported endpoint version."
      } elseif ($status -eq 401) {
        Write-Warning "401 Unauthorized – token expired or wrong scopes." }
    } else {
      Write-Warning "No HTTP response object present."
    }
    throw
  }
}

# 1) Enumerate via views endpoint instead of tables (tables endpoint returning 400 in tenant)
$base = "$Domain/restapi/v2/workspaces/$WorkspaceId"
$schema = [ordered]@{ generatedAt = (Get-Date).ToString('s'); domain = $Domain; workspaceId = $WorkspaceId; tables = [ordered]@{}; views = [ordered]@{} }

function Add-Views($collection, $target) {
  foreach ($v in $collection) {
    $vid = $v.id; if (-not $vid) { $vid = $v.viewId }
    $vname = $v.name; if (-not $vname) { $vname = $v.viewName }; if (-not $vname) { $vname = $v.displayName }
    $vtype = $v.type; if (-not $vtype) { $vtype = $v.viewType }
    if (-not $vid -or -not $vname) { continue }
    $vcolsUrl = "$base/views/$vid/columns"
    $vcolsResp = Get-Json $vcolsUrl
    $vcolsPayload = $vcolsResp.data
    $vcols = $null
    if ($vcolsPayload -and $vcolsPayload.columns) { $vcols = $vcolsPayload.columns }
    if (-not $vcols) { $vcols = $vcolsResp.columns }
    if (-not $vcols) { $vcols = $vcolsResp.data }
    $colsSlim = @()
    foreach ($c in $vcols) {
      $colsSlim += [pscustomobject]@{
        name        = ($c.name ? $c.name : $c.columnName)
        label       = ($c.displayName ? $c.displayName : $c.columnDisplayName)
        dataType    = ($c.dataType ? $c.dataType : $c.columnType)
        isFormula   = [bool]($c.isFormula)
        description = $c.description
      }
    }
    $target[$vname] = [pscustomobject]@{ id=$vid; type=$vtype; columns=$colsSlim }
  }
}

try {
  $tableResp = Get-Json "$base/views?type=TABLE&action=LIST"
  $tablePayload = $tableResp.data
  $tableViews = $null
  if ($tablePayload -and $tablePayload.views) { $tableViews = $tablePayload.views } else { $tableViews = $tableResp.views }
  if ($tableViews) { Add-Views $tableViews $schema.tables } else { Write-Warning "No TABLE views returned." }
} catch { Write-Warning "Failed to enumerate TABLE views: $($_.Exception.Message)" }

# 2) Query Tables only
try {
  $qtResp = Get-Json "$base/views?type=QUERY_TABLE&action=LIST"
  $qtPayload = $qtResp.data
  $qtViews = $null
  if ($qtPayload -and $qtPayload.views) { $qtViews = $qtPayload.views } else { $qtViews = $qtResp.views }
  if ($qtViews) { Add-Views $qtViews $schema.views } else { Write-Warning "No QUERY_TABLE views returned." }
} catch { Write-Warning "Query table enumeration failed: $($_.Exception.Message)" }

# 3) Write file (to tools/analytics by default)
$OutPath = if ([System.IO.Path]::IsPathRooted($OutFile)) { $OutFile } else { Join-Path -Path (Split-Path -Parent $MyInvocation.MyCommand.Path) -ChildPath $OutFile }
$schema | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $OutPath
Write-Host "Schema written to $OutPath" -ForegroundColor Green
