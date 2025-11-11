<#
Quick diagnostics script to query Zoho Books custom module cm_item_monthly_sales.
USAGE (PowerShell):
  $env:ZB_TOKEN="Zoho-oauthtoken 1000.xxxxxx..."   # Access token (include the Zoho-oauthtoken prefix)
  $org="YOUR_ORG_ID"
  $dc="com"  # or eu / in / au / jp etc.
  $sku="123-ABC"  # sample SKU to filter client-side
  .\query_cm_item_monthly_sales.ps1 -OrganizationId $org -DataCenter $dc -Sku $sku -Pages 3 -PerPage 200

Obtains pages 1..N and prints basic counts plus rows for the chosen SKU.
NOTE: Do NOT commit real tokens. Keep token in env variable only.
#>
param(
  [Parameter(Mandatory=$true)][string]$OrganizationId,
  [Parameter(Mandatory=$true)][string]$DataCenter,  # e.g. com, eu, in
  [Parameter()][string]$Sku = "",
  [Parameter()][int]$Pages = 2,
  [Parameter()][int]$PerPage = 200,
  [Parameter()][string]$Token,
  [Parameter()][string]$ModuleName,
  [Parameter()][switch]$ListModules,            # Just list available custom modules then exit
  [Parameter()][switch]$DebugSchema,            # Emit top-level keys of each page JSON for debugging
  [Parameter()][int]$Months = 24,               # If SKU provided, limit final month buckets (most recent first)
  [Parameter()][switch]$TryCriteria,            # Try server-side filtering (?criteria=)
  [Parameter()][string]$MinMonth                # Optional YYYY-MM lower bound for criteria
)

$ErrorActionPreference = "Stop"
if (-not $Token) {
  if (-not $env:ZB_TOKEN) { Write-Error "Set ZB_TOKEN env var (include 'Zoho-oauthtoken ' prefix) or pass -Token." }
  $token = $env:ZB_TOKEN.Trim()
} else {
  $token = $Token.Trim()
}
if (-not $token.StartsWith("Zoho-oauthtoken")) { Write-Warning "Token should start with 'Zoho-oauthtoken'." }

$apiRoot = "https://www.zohoapis.$DataCenter/books/v3"

# Helper: generic GET with error handling
function Invoke-ZohoGet($url) {
  Write-Host "GET: $url" -ForegroundColor Yellow
  try {
    return Invoke-RestMethod -Method Get -Uri $url -Headers @{ Authorization = $token; Accept = 'application/json' } -ErrorAction Stop
  } catch {
    Write-Warning ("Request failed: " + $_.Exception.Message)
    return $null
  }
}

# Optional: list all custom modules to confirm API name
if ($ListModules) {
  $listUrl = $apiRoot + "/settings/custommodules?organization_id=" + $OrganizationId
  Write-Host "\n=== Listing Custom Modules ===" -ForegroundColor Cyan
  $modsJson = Invoke-ZohoGet $listUrl
  if (-not $modsJson) {
    # Fallback probe: some stacks expose list under /custommodules
    $listUrl = $apiRoot + "/custommodules?organization_id=" + $OrganizationId
    Write-Host "Fallback list URL: $listUrl" -ForegroundColor DarkCyan
    $modsJson = Invoke-ZohoGet $listUrl
  }
  if ($modsJson) {
    # Persist raw list for inspection
    try { ($modsJson | ConvertTo-Json -Depth 6) | Out-File -FilePath (Join-Path $PSScriptRoot "custom_modules_list.json") -Encoding UTF8 } catch {}
    $arr = @()
    if ($modsJson.custom_modules) { $arr = $modsJson.custom_modules }
    elseif ($modsJson.modules) { $arr = $modsJson.modules }
    $arr | Select-Object api_name, display_name, is_active, created_time | Format-Table -AutoSize
    Write-Host ("Total modules: " + ($arr.Count)) -ForegroundColor Green
    if ($ModuleName) {
      $match = $arr | Where-Object { $_.api_name -eq $ModuleName }
      if ($match) { Write-Host "Module '$ModuleName' FOUND in list." -ForegroundColor Green } else { Write-Warning "Module '$ModuleName' not found in returned list." }
    }
  }
  Write-Host "Exiting after module list (use without -ListModules to pull records)." -ForegroundColor Cyan
  return
}
$candidates = @()
if ($ModuleName -and $ModuleName.Trim() -ne "") {
  $candidates = @($ModuleName.Trim())
} else {
  # Try a few likely API names
  $candidates = @('cm_item_monthly_sales','item_monthly_sales','cm_item_sales')
}

foreach ($mod in $candidates) {
  $base = "$apiRoot/$mod"
  Write-Host "\n=== Trying endpoint: $base ===" -ForegroundColor Cyan
  $allRows = @()
  $skuMatchRows = @()
  $skipBroadPaging = $false

  # Optional criteria-first query to fetch only the target SKU (and optionally month range)
  if ($TryCriteria -and $Sku) {
    $SkuTrim = $Sku.Trim()
    $crit = "(cf_sku:equals:" + $SkuTrim + ")"
    if ($MinMonth -and $MinMonth.Trim() -ne "") {
      $crit = $crit + "and(cf_month_year:greater_or_equals:" + ($MinMonth.Trim()) + ")"
    }
    $critEnc = [System.Uri]::EscapeDataString($crit)
  for ($p=1; $p -le $Pages; $p++) {
      $url = $base + "?organization_id=" + $OrganizationId + "&criteria=" + $critEnc + "&page=" + $p + "&per_page=" + $PerPage + "&sort_column=cf_month_year&sort_order=D"
      Write-Host ("Criteria page " + $p + " URL: " + $url) -ForegroundColor Yellow
      $json = Invoke-ZohoGet $url
      if (-not $json) { break }
      try { ($json | ConvertTo-Json -Depth 8) | Out-File -FilePath (Join-Path $PSScriptRoot ("last_criteria_" + $mod + "_page_" + $p + ".json")) -Encoding UTF8 } catch {}
      $rows = @()
      if ($json.module_records) { $rows = $json.module_records }
      elseif ($json.module_record) { $rows = $json.module_record }
      elseif ($json.records) { $rows = $json.records }
      elseif ($json.data) { $rows = $json.data }
      $count = ($rows | Measure-Object).Count
      Write-Host "Criteria rows: $count" -ForegroundColor Green
      if ($count -eq 0) { break }
      $allRows += $rows
      # Always enforce client-side filter as criteria may be ignored by API
      $pageSkuRows = $rows | Where-Object { $_.cf_sku -eq $SkuTrim }
      if ($pageSkuRows) { $skuMatchRows += $pageSkuRows }
      if ($json.page_context) {
        if (-not $json.page_context.has_more_page) { break }
      } else {
        if ($count -lt $PerPage) { break }
      }
    }
    if ($skuMatchRows.Count -gt 0) {
      Write-Host ("Criteria returned matches (" + $skuMatchRows.Count + "). Skipping broad pagination for SKU scan.") -ForegroundColor DarkGreen
      $skipBroadPaging = $true
    }
  }
  if (-not $skipBroadPaging) {
    for ($p=1; $p -le $Pages; $p++) {
    $url = $base + "?organization_id=" + $OrganizationId + "&page=" + $p + "&per_page=" + $PerPage + "&sort_column=cf_month_year&sort_order=D"
    Write-Host ("Page " + $p + " URL: " + $url) -ForegroundColor Yellow
    $json = Invoke-ZohoGet $url
    if (-not $json) { break }
    if ($null -eq $json) { Write-Warning "Null JSON for page $p"; break }
    # Persist raw response for inspection
    try { ($json | ConvertTo-Json -Depth 8) | Out-File -FilePath (Join-Path $PSScriptRoot ("last_" + $mod + "_page_" + $p + ".json")) -Encoding UTF8 } catch {}
    if ($DebugSchema) {
      $topKeys = ($json | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
      Write-Host ("Top-level keys: " + ($topKeys -join ', ')) -ForegroundColor DarkGray
    }
  $rows = @()
  if ($json.module_records) { $rows = $json.module_records }
  elseif ($json.module_record) { $rows = $json.module_record }
    elseif ($json.records) { $rows = $json.records }
    elseif ($json.data) { $rows = $json.data }
    $count = ($rows | Measure-Object).Count
    Write-Host "Rows: $count" -ForegroundColor Green
    if ($count -eq 0) { break }
    $allRows += $rows
    if ($Sku) {
      $SkuTrim = $Sku.Trim()
      $pageSkuRows = $rows | Where-Object { $_.cf_sku -eq $SkuTrim }
      if ($pageSkuRows) { $skuMatchRows += $pageSkuRows }
    }
    if ($json.page_context) {
      $hasMore = $json.page_context.has_more_page
      Write-Host "has_more_page: $hasMore" -ForegroundColor Magenta
      if (-not $hasMore) { break }
    } else {
      if ($count -lt $PerPage) { break }
    }
    }
  }
  Write-Host "Total collected rows (primary endpoint): $($allRows.Count)" -ForegroundColor Cyan
  if ($allRows.Count -eq 0) {
    # Try legacy /custommodules/<api>/records
    $legacyBase = "$apiRoot/custommodules/$mod/records"
    Write-Host "Trying legacy endpoint: $legacyBase" -ForegroundColor DarkCyan
    $allRows = @()
    for ($p=1; $p -le $Pages; $p++) {
      $url = $legacyBase + "?organization_id=" + $OrganizationId + "&page=" + $p + "&per_page=" + $PerPage + "&sort_column=cf_month_year&sort_order=D"
      Write-Host ("Legacy page " + $p + " URL: " + $url) -ForegroundColor Yellow
      $json = Invoke-ZohoGet $url
      if (-not $json) { break }
      if ($null -eq $json) { Write-Warning "Null JSON for legacy page $p"; break }
      try { ($json | ConvertTo-Json -Depth 8) | Out-File -FilePath (Join-Path $PSScriptRoot ("last_legacy_" + $mod + "_page_" + $p + ".json")) -Encoding UTF8 } catch {}
      if ($DebugSchema) {
        $topKeys = ($json | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
        Write-Host ("Top-level keys (legacy): " + ($topKeys -join ', ')) -ForegroundColor DarkGray
      }
  $rows = @()
  if ($json.module_records) { $rows = $json.module_records }
  elseif ($json.module_record) { $rows = $json.module_record }
      elseif ($json.records) { $rows = $json.records }
      elseif ($json.data) { $rows = $json.data }
      $count = ($rows | Measure-Object).Count
      Write-Host "Rows: $count" -ForegroundColor Green
      if ($count -eq 0) { break }
      $allRows += $rows
      if ($json.page_context) {
        $hasMore = $json.page_context.has_more_page
        Write-Host "has_more_page: $hasMore" -ForegroundColor Magenta
        if (-not $hasMore) { break }
      } else {
        if ($count -lt $PerPage) { break }
      }
    }
    Write-Host "Total collected rows (legacy endpoint): $($allRows.Count)" -ForegroundColor Cyan
  }

  if ($Sku -and $Sku.Trim() -ne "") {
    $SkuTrim = $Sku.Trim()
    $skuRows = $skuMatchRows
    Write-Host "Rows matching SKU '$SkuTrim': $($skuRows.Count)" -ForegroundColor Cyan
    if ($skuRows.Count -gt 0) {
      # Build month -> totals map
      $grouped = $skuRows | Group-Object -Property cf_month_year | Sort-Object Name -Descending
      $limited = $grouped | Select-Object -First $Months
      Write-Host ("Most recent " + $Months + " month buckets (Qty, Net Sales):") -ForegroundColor Magenta
      $limited | ForEach-Object {
        $mm = $_.Name
        $qty = ($_.Group | Measure-Object -Property cf_total_quantity -Sum).Sum
        $sales = ($_.Group | Measure-Object -Property cf_net_sales -Sum).Sum
        Write-Host ("  " + $mm + " | Qty=" + $qty + " | Sales=" + $sales)
      }
      Write-Host "Detailed rows:" -ForegroundColor Magenta
      $skuRows | Select-Object cf_sku, cf_month_year, cf_total_quantity, cf_net_sales | Sort-Object cf_month_year -Descending | Format-Table -AutoSize
    }
  }
}
