<#!
.SYNOPSIS
    Safely identify and archive redundant CSV data artifacts in the /data folder.
.DESCRIPTION
    Classifies files into KEEP and ARCHIVE candidates based on patterns:
      - Keep canonical enriched snapshots (item_snapshot_enriched_canonical_v2.csv, item_snapshot_enriched_flat_tbl_v2.csv)
      - Keep KPI input tables (qt_sales_24m.csv, qt_last_purchase.csv, qt_last_purchase_fallback.csv, qt_stock_on_hand_final_v3.csv,
        qt_outstanding_po_precise.csv, qt_reorder_candidates.csv, qt_items_fallback.csv)
      - Keep flow tables (Stock_In_Flow_Table.csv, Stock_Out_Flow_Table.csv)
      - Keep current inventory export (Inventory_Items_Export_* latest by timestamp)
      - Keep calendar/reference (calendar_months.csv, kpi_* CSVs)
      - Archive older/intermediate snapshots (qt_item_snapshot*.csv except canonical/flat_tbl_v2)
      - Archive nested Zoho_Finance_Analytics(<n>) folders except the numerically highest (latest) plus EXPORT + partial export
    Modes:
      preview (default) -> show plan
      archive -> move ARCHIVE candidates into data/ARCHIVE_<yyyy-MM-dd>/
      delete  -> permanently remove ARCHIVE candidates (USE WITH CAUTION)
.PARAMETER Root
    Root data directory (default: project data folder)
.PARAMETER Mode
    preview | archive | delete
.EXAMPLE
    pwsh ./tools/diagnostics/cleanup_data.ps1 -Mode preview
.EXAMPLE
    pwsh ./tools/diagnostics/cleanup_data.ps1 -Mode archive
.NOTES
    Non-destructive by default. Adjust keepPatterns if new canonical files added.
#> 
param(
    [string]$Root = "$(Resolve-Path -Path (Join-Path $PSScriptRoot '..' '..' 'data'))",
    [ValidateSet('preview','archive','delete')][string]$Mode = 'preview'
)

if(-not (Test-Path $Root)) { Write-Error "Root path not found: $Root"; exit 1 }

$today = Get-Date -Format 'yyyy-MM-dd'
$archiveDir = Join-Path $Root "ARCHIVE_$today"

$keepFiles = @(
  'item_snapshot_enriched_canonical_v2.csv',
  'item_snapshot_enriched_flat_tbl_v2.csv',
  'qt_sales_24m.csv',
  'qt_last_purchase.csv',
  'qt_last_purchase_fallback.csv',
  'qt_stock_on_hand_final_v3.csv',
  'qt_outstanding_po_precise.csv',
  'qt_reorder_candidates.csv',
  'qt_items_fallback.csv',
  'Stock_In_Flow_Table.csv',
  'Stock_Out_Flow_Table.csv',
  'calendar_months.csv'
)

# Always keep KPI summary tables and README
$keepPrefix = @('kpi_')
$mandatoryKeep = @('README.md')

# Latest Inventory_Items_Export_* keep; older same pattern archive
$inventoryExports = Get-ChildItem -Path $Root -File -Filter 'Inventory_Items_Export_*.csv' | Sort-Object LastWriteTime -Descending
if($inventoryExports.Count -gt 0){
  $keepFiles += $inventoryExports[0].Name
}

# Collect all CSV files
$allCsv = Get-ChildItem -Path $Root -File -Filter '*.csv'

# Determine keep set
$keepSet = [System.Collections.Generic.HashSet[string]]::new()
foreach($f in $keepFiles){ $keepSet.Add($f) }
foreach($f in $allCsv){
  if($keepPrefix | ForEach-Object { $f.Name.StartsWith($_) } | Where-Object { $_ -eq $true }){ $keepSet.Add($f.Name) }
  if($mandatoryKeep -contains $f.Name){ $keepSet.Add($f.Name) }
}

# Snapshot variants to archive (older item_snapshot & qt_item_snapshot*) unless canonical/flat kept
$archiveCandidates = @()
foreach($f in $allCsv){
  $n = $f.Name
  if($keepSet.Contains($n)){ continue }
  if($n -match '^qt_item_snapshot' -or $n -match '^item_snapshot'){
     $archiveCandidates += $f; continue
  }
  # Intermediate qt_* not in keep list
  if($n -match '^qt_' -and -not $keepSet.Contains($n)){
     $archiveCandidates += $f; continue
  }
  # Older inventory exports except newest
  if($inventoryExports.Count -gt 1 -and $inventoryExports[0].Name -ne $n -and $n -like 'Inventory_Items_Export_*.csv'){
     $archiveCandidates += $f; continue
  }
}

# Folder handling: keep highest numbered Zoho_Finance_Analytics(n), export, partial export
$analyticsDirs = Get-ChildItem -Path $Root -Directory | Where-Object { $_.Name -like 'Zoho_Finance_Analytics(*)' }
$highestDir = $null
if($analyticsDirs){
  $highestDir = ($analyticsDirs | Sort-Object { [int]($_.Name -replace 'Zoho_Finance_Analytics\(|\)','') } -Descending | Select-Object -First 1)
}
$dirArchiveCandidates = @()
foreach($d in $analyticsDirs){
  if($highestDir -and $d.FullName -eq $highestDir.FullName){ continue }
  $dirArchiveCandidates += $d
}
# Never archive export or partial export folders automatically
$specialDirs = Get-ChildItem -Path $Root -Directory | Where-Object { $_.Name -in @('Zoho_Finance_Analytics_EXPORT','Zoho_Finance_Analytics_partial_export_Nov2025','ALL_WORKSPACE_TABLES','DIAG','Purchase_Receive_New_Detail') }
$dirArchiveCandidates = $dirArchiveCandidates | Where-Object { $specialDirs.Name -notcontains $_.Name }

$keepArray = @()
foreach($k in $keepSet){ $keepArray += $k }
$result = [PSCustomObject]@{
  Root = $Root
  Mode = $Mode
  KeepFiles = ($keepArray | Sort-Object)
  ArchiveFileCount = $archiveCandidates.Count
  ArchiveFiles = $archiveCandidates.Name
  ArchiveDirCandidates = $dirArchiveCandidates.Name
  HighestAnalyticsDir = $highestDir?.Name
}

if($Mode -eq 'preview'){
  $result | Format-List
  Write-Host "\nPreview complete. To archive run: pwsh $PSCommandPath -Mode archive" -ForegroundColor Cyan
  exit 0
}

if($Mode -eq 'archive'){
  if(-not (Test-Path $archiveDir)){ New-Item -ItemType Directory -Path $archiveDir | Out-Null }
  foreach($f in $archiveCandidates){ Move-Item -LiteralPath $f.FullName -Destination $archiveDir -Force }
  foreach($d in $dirArchiveCandidates){
     $dest = Join-Path $archiveDir $d.Name
     Move-Item -LiteralPath $d.FullName -Destination $dest -Force
  }
  $result | Format-List
  Write-Host "\nArchive complete -> $archiveDir" -ForegroundColor Green
  exit 0
}

if($Mode -eq 'delete'){
  Write-Warning "DELETE mode: permanently removing archive candidates."
  foreach($f in $archiveCandidates){ Remove-Item -LiteralPath $f.FullName -Force }
  foreach($d in $dirArchiveCandidates){ Remove-Item -LiteralPath $d.FullName -Recurse -Force }
  $result | Format-List
  Write-Host "\nDelete complete." -ForegroundColor Red
  exit 0
}
