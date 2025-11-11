param(
  [Parameter(Mandatory=$true)][string]$OrganizationId,
  [Parameter(Mandatory=$true)][string]$DataCenter,
  [Parameter(Mandatory=$true)][string]$InputCsv,
  [Parameter()][string]$ModuleName = 'cm_item_monthly_sales',
  [Parameter()][string]$Token,
  [Parameter()][string]$Sku,
  [Parameter()][string]$StartMonth,   # YYYY-MM inclusive
  [Parameter()][string]$EndMonth,     # YYYY-MM inclusive
  [Parameter()][switch]$DryRun = $true
)

$ErrorActionPreference = 'Stop'
if (-not $Token) {
  if (-not $env:ZB_TOKEN) { throw "Set ZB_TOKEN or pass -Token (include 'Zoho-oauthtoken ' prefix)." }
  $token = $env:ZB_TOKEN.Trim()
} else { $token = $Token.Trim() }

if (-not (Test-Path -Path $InputCsv)) { throw "Input CSV not found: $InputCsv" }

function Invoke-ZohoGet($url) {
  try { return Invoke-RestMethod -Method Get -Uri $url -Headers @{ Authorization = $token; Accept='application/json' } -ErrorAction Stop }
  catch { Write-Warning ("GET failed: " + $_.Exception.Message); return $null }
}
function Invoke-ZohoPost($url, $bodyObj) {
  $json = $bodyObj | ConvertTo-Json -Depth 6
  try { return Invoke-RestMethod -Method Post -Uri $url -Headers @{ Authorization = $token; 'Content-Type'='application/json' } -Body $json -ErrorAction Stop }
  catch { Write-Warning ("POST failed: " + $_.Exception.Message); return $null }
}

$apiRoot = "https://www.zohoapis.$DataCenter/books/v3"
$base = "$apiRoot/$ModuleName"

Write-Host "Collecting existing keys from module (for de-dup) ..." -ForegroundColor Cyan
$existing = New-Object System.Collections.Generic.HashSet[string]
for ($p=1; $p -le 200; $p++) {
  $url = $base + "?organization_id=" + $OrganizationId + "&page=" + $p + "&per_page=200&sort_column=cf_month_year&sort_order=D"
  $res = Invoke-ZohoGet $url
  if (-not $res) { break }
  $rows = @()
  if ($res.module_records) { $rows = $res.module_records }
  elseif ($res.module_record) { $rows = $res.module_record }
  elseif ($res.records) { $rows = $res.records }
  elseif ($res.data) { $rows = $res.data }
  $cnt = ($rows | Measure-Object).Count
  if ($cnt -eq 0) { break }
  foreach ($r in $rows) {
    if ($r.cf_key) { [void]$existing.Add([string]$r.cf_key) }
  }
  if ($res.page_context -and (-not $res.page_context.has_more_page)) { break }
}
Write-Host ("Existing keys collected: " + $existing.Count) -ForegroundColor Green

# Load input
$rows = Import-Csv -Path $InputCsv
$monthRegex = '^(?<y>\d{4})-(?<m>0[1-9]|1[0-2])$'

# Normalize filters
$skuFilter = $Sku
$startKey = if ($StartMonth -and ($StartMonth -match $monthRegex)) { [int]("$($Matches.y)$($Matches.m)") } else { $null }
$endKey   = if ($EndMonth   -and ($EndMonth   -match $monthRegex)) { [int]("$($Matches.y)$($Matches.m)") } else { $null }

$toCreate = @()
foreach ($r in $rows) {
  $key = $r.key
  $itemId = $r.item_id
  $sku = $r.sku
  $name = $r.item_name
  $month = $r.month_year
  $qty = [double]$r.total_quantity
  $sales = [double]$r.net_sales
  $last = if ($r.last_updated) { [string]$r.last_updated } else { (Get-Date).ToString('yyyy-MM-dd HH:mm') }

  if ([string]::IsNullOrWhiteSpace($key) -or [string]::IsNullOrWhiteSpace($itemId) -or [string]::IsNullOrWhiteSpace($month)) { continue }
  if ($skuFilter -and $sku -ne $skuFilter) { continue }
  if (-not ($month -match $monthRegex)) { continue }
  $monKey = [int]("$($Matches.y)$($Matches.m)")
  if ($startKey -ne $null -and $monKey -lt $startKey) { continue }
  if ($endKey   -ne $null -and $monKey -gt $endKey)   { continue }
  if ($existing.Contains([string]$key)) { continue }

  $rec = [ordered]@{
    module_api_name = $ModuleName
    module_record   = [ordered]@{
      module_api_name   = $ModuleName
      cf_key            = [string]$key
      cf_item_id        = [string]$itemId
      cf_sku            = [string]$sku
      cf_item_name      = [string]$name
      cf_month_year     = [string]$month
      cf_total_quantity = [double]$qty
      cf_net_sales      = [double]$sales
      cf_last_updated   = [string]$last
    }
  }
  $toCreate += $rec
}

Write-Host ("Records to create: " + $toCreate.Count) -ForegroundColor Cyan
if ($DryRun) {
  Write-Host "DryRun: no changes sent. Previewing first 3 payloads:" -ForegroundColor Yellow
  $toCreate | Select-Object -First 3 | ForEach-Object { $_ | ConvertTo-Json -Depth 6 | Write-Output }
  return
}

# Create sequentially (Books API doesn't support bulk create for custom modules)
$created = 0
foreach ($body in $toCreate) {
  $resp = Invoke-ZohoPost $base $body
  if ($resp -and $resp.code -eq 0) { $created++ } else { Write-Warning ("Create failed for key: " + $body.module_record.cf_key) }
  Start-Sleep -Milliseconds 150
}
Write-Host ("Created: $created / $($toCreate.Count)") -ForegroundColor Green
