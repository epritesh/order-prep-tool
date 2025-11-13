<#
.SYNOPSIS
  Generates an explicit SELECT list for Zoho Analytics that removes dotted/aliased column headers.

.DESCRIPTION
  When you create a new Query Table like:
      SELECT * FROM "item_snapshot_enriched_flat_tbl_v2" t
  Zoho will include the table alias in the column labels (e.g., t.Item_ID), producing "dotted headers".
  Paste the output of this script into the Zoho SQL editor to select each column explicitly and alias it
  back to a clean identifier (no dots, spaces, or symbols).

.PARAMETER InputCsv
  A CSV file whose header row lists the columns to include (e.g., data\item_snapshot_enriched_flat_tbl_v2.csv).

.PARAMETER TableName
  The source table name in Zoho. Defaults to item_snapshot_enriched_flat_tbl_v2.

.PARAMETER Alias
  The alias to use for the source table in the SELECT. Defaults to t.

.EXAMPLE
  pwsh -File tools/analytics/generate_zoho_select_list.ps1 -InputCsv data/item_snapshot_enriched_flat_tbl_v2.csv \
       -TableName item_snapshot_enriched_flat_tbl_v2 -Alias t

  Output (trimmed):
    SELECT
      "t"."Item_ID"            AS Item_ID,
      "t"."SKU"                 AS SKU,
      ...
    FROM "item_snapshot_enriched_flat_tbl_v2" "t";

.NOTES
  - This is a helper to avoid manual renaming in Zoho.
  - If your Zoho table has extra computed columns not in the CSV, add them manually after pasting.
#>
param(
  [Parameter(Mandatory=$true)]
  [string]$InputCsv,
  [string]$TableName = 'item_snapshot_enriched_flat_tbl_v2',
  [string]$Alias = 't'
)

if (!(Test-Path -Path $InputCsv)) {
  Write-Error "Input CSV not found: $InputCsv"
  exit 1
}

# Read header row robustly
$firstLine = (Get-Content -Path $InputCsv -TotalCount 1)
if (-not $firstLine) {
  Write-Error 'CSV appears empty.'
  exit 1
}

# Split on commas, respecting the common case where headers are simple and quoted
# If a header itself contains commas, this basic split may fail; for our dataset headers are simple.
$rawHeaders = @()
if ($firstLine -match '^[\s]*"') {
  # Likely quoted headers -> capture text inside quotes
  $rawHeaders = [System.Text.RegularExpressions.Regex]::Matches($firstLine, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value }
}
if (-not $rawHeaders -or $rawHeaders.Count -eq 0) {
  $rawHeaders = $firstLine -split ',' | ForEach-Object { $_.Trim('"').Trim() }
}

function Sanitize([string]$name) {
  $clean = $name -replace '[^\p{L}\p{Nd}_]', '_'  # keep letters, numbers, underscore
  $clean = $clean -replace '_+', '_'               # collapse repeats
  $clean = $clean.Trim('_')
  if ($clean -match '^[0-9]') { $clean = '_' + $clean }
  if ([string]::IsNullOrWhiteSpace($clean)) { $clean = 'col_' + ([guid]::NewGuid().ToString('N').Substring(0,6)) }
  return $clean
}

$lines = @()
foreach ($h in $rawHeaders) {
  if ([string]::IsNullOrWhiteSpace($h)) { continue }
  $aliasName = Sanitize $h
  # Quote identifiers for Zoho (double-quotes)
  $src = '"{0}"."{1}"' -f $Alias, $h
  $lines += ('  {0,-40} AS {1}' -f $src, $aliasName)
}

# Emit full SELECT statement
Write-Output 'SELECT'
$lastIndex = $lines.Count - 1
for ($i=0; $i -lt $lines.Count; $i++) {
  if ($i -lt $lastIndex) { Write-Output ($lines[$i] + ',') } else { Write-Output $lines[$i] }
}
$from = 'FROM "{0}" "{1}";' -f $TableName, $Alias
Write-Output $from