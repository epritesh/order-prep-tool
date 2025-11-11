<#
  remaining_poi_dates.ps1
  Purpose: List creation dates (from 'Created Time') for PO item rows whose Purchase Order ID does NOT appear in Purchase_Receive.csv (i.e., not yet received).
  Output: Table of CreatedDate, RemainingItemRows plus summary (distinct dates, earliest, latest, total remaining rows).

  Usage:
    pwsh -NoLogo -NoProfile -File .\remaining_poi_dates.ps1 \
      -PoItemsCsv "..\..\data\Zoho_Finance_Analytics_partial_export_Nov2025\Purchase_Order_Items.csv" \
      -PoReceiveCsv "..\..\data\Zoho_Finance_Analytics_partial_export_Nov2025\Purchase_Receive.csv"

  Notes:
  - Assumes columns: "Purchase Order ID" in both files; uses "Created Time" from Purchase_Order_Items.csv as proxy for PO creation date.
  - If Created Time is missing or unparsable, those rows are skipped.
    - Large CSVs: Using Import-Csv (streaming not required for current size).
#>
param(
  [Parameter(Mandatory=$true)] [string] $PoItemsCsv,
  [Parameter(Mandatory=$true)] [string] $PoReceiveCsv
)

if(!(Test-Path $PoItemsCsv)){ throw "PO Items CSV not found: $PoItemsCsv" }
if(!(Test-Path $PoReceiveCsv)){ throw "PO Receive CSV not found: $PoReceiveCsv" }

Write-Host "Loading Purchase Order Receive headers..." -ForegroundColor Cyan
$receive = Import-Csv -Path $PoReceiveCsv
$receivedIds = ($receive | Where-Object { $_.'Purchase Order ID' -and $_.'Purchase Order ID'.Trim() -ne '' } | Select-Object -ExpandProperty 'Purchase Order ID' -Unique)

Write-Host "Loading Purchase Order Items..." -ForegroundColor Cyan
$poi = Import-Csv -Path $PoItemsCsv

# Filter remaining item rows (PO IDs not in receipts)
$remaining = $poi | Where-Object { $receivedIds -notcontains $_.'Purchase Order ID' }

<#
  Created Time format examples: 2023-09-12 11:02:15
  We'll extract the date portion.
#>
$remainingWithDates = $remaining | ForEach-Object {
  $raw = $_.'Created Time'
  $parsed = $null
  if($raw){
    try { $parsed = [DateTime]::Parse($raw) } catch { }
  }
  if($parsed){ [pscustomobject]@{ 'CreatedDate' = $parsed.Date; 'Purchase Order ID' = $_.'Purchase Order ID' } }
}

$grouped = $remainingWithDates | Group-Object CreatedDate | Sort-Object Name

$totalRemaining = $remaining.Count
$datedCount = $remainingWithDates.Count
$distinctDates = $grouped.Count
$earliest = ($grouped | Select-Object -First 1).Name
$latest = ($grouped | Select-Object -Last 1).Name

Write-Host "\nRemaining PO Item Rows Creation Date Distribution:" -ForegroundColor Yellow
$byDate = $grouped | Select-Object @{Name='CreatedDate';Expression={ ([DateTime]$_.Name).ToString('yyyy-MM-dd')}}, @{Name='RemainingItemRows';Expression={$_.Count}}
$byDate | Format-Table -AutoSize

Write-Host "\nSummary:" -ForegroundColor Yellow
Write-Host ("Total Remaining Item Rows: {0}" -f $totalRemaining)
Write-Host ("Remaining Rows With Parseable Dates: {0}" -f $datedCount)
Write-Host ("Distinct Dates: {0}" -f $distinctDates)
if($earliest){ Write-Host ("Earliest Created Date: {0}" -f ([DateTime]$earliest).ToString('yyyy-MM-dd')) }
if($latest){ Write-Host ("Latest Created Date: {0}" -f ([DateTime]$latest).ToString('yyyy-MM-dd')) }

Write-Host "\nCSV Export (optional) -> remaining_poi_created_dates_output.csv" -ForegroundColor Cyan
$byDate | Export-Csv -Path (Join-Path (Split-Path $PoItemsCsv -Parent) 'remaining_poi_created_dates_output.csv') -NoTypeInformation

# Month-level profile and suggested cutoff helpers
$asOf = [DateTime]::Parse('2025-11-07')
$byMonth = $remainingWithDates | ForEach-Object {
  $m = New-Object DateTime $_.CreatedDate.Year, $_.CreatedDate.Month, 1
  [pscustomobject]@{ Month=$m; Count=1 }
} | Group-Object Month | Sort-Object Name | ForEach-Object {
  [pscustomobject]@{ Month=([DateTime]$_.Name); Count=$_.Count; AgeMonths=[int](([TimeSpan]($asOf - ([DateTime]$_.Name))).TotalDays/30) }
}

Write-Host "\nRemaining PO Item Rows by Creation Month:" -ForegroundColor Yellow
$byMonth | Select-Object @{Name='Month';Expression={ $_.Month.ToString('yyyy-MM')}}, Count, AgeMonths | Format-Table -AutoSize

# Threshold summary
$total = $totalRemaining
$thresholds = 3,6,9,12,15,18,24
Write-Host "\nCutoff scenarios (older than X months):" -ForegroundColor Yellow
foreach($t in $thresholds){
  $older = ($remainingWithDates | Where-Object { (($asOf - $_.CreatedDate).TotalDays/30) -gt $t }).Count
  $pct = if($total -gt 0){ [Math]::Round(($older * 100.0 / $total),1) } else { 0 }
  Write-Host ("X={0,2} mo -> Remove {1} rows ({2}%); Keep {3}" -f $t, $older, $pct, ($total - $older))
}

Write-Host "\nCSV Export (optional) -> remaining_poi_created_months_output.csv" -ForegroundColor Cyan
$byMonth | Select-Object @{Name='Month';Expression={ $_.Month.ToString('yyyy-MM')}}, Count, AgeMonths |
  Export-Csv -Path (Join-Path (Split-Path $PoItemsCsv -Parent) 'remaining_poi_created_months_output.csv') -NoTypeInformation

Write-Host "Done." -ForegroundColor Green