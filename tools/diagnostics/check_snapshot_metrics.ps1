param(
    [string]$Path = "c:\\Users\\eprit\\Projects\\Pantera\\order-prep-tool\\data\\qt_item_snapshot_sales_enriched_v4.csv"
)

if (!(Test-Path -LiteralPath $Path)) {
    Write-Error "File not found: $Path"
    exit 1
}

$rows = Import-Csv -LiteralPath $Path
$total = $rows.Count

# Resolve header names that may be flattened (v4b) or dotted (v4)
$headers = @()
if ($rows.Count -gt 0) { $headers = $rows[0].PSObject.Properties.Name }

function Pick-HeaderName {
    param([string[]]$Candidates)
    foreach ($c in $Candidates) { if ($headers -contains $c) { return $c } }
    return $null
}

$colDemand = Pick-HeaderName @('Avg_Demand_Used','db.Avg_Demand_Used')
$colSOHQty = Pick-HeaderName @('On_Hand_Qty','soh.On_Hand_Qty')
$colLP     = Pick-HeaderName @('Last_Purchase_Price','lp.Last_Purchase_Price')
$colLPPF   = Pick-HeaderName @('Last_Purchase_Price_Fallback')
$colRate   = Pick-HeaderName @('Current_Unit_Rate','itf.Current_Unit_Rate')

$hasDemand = if ($colDemand) { ($rows | Where-Object { $_.$colDemand -and [double]($_.$colDemand) -gt 0 }).Count } else { 0 }
$hasSOH    = if ($colSOHQty) { ($rows | Where-Object { $_.$colSOHQty -and ("{0}" -f $_.$colSOHQty).Trim() -ne '' }).Count } else { 0 }
$hasLP     = if ($colLP -or $colLPPF) { (
    $rows | Where-Object {
        ($colLP -and $_.$colLP -and ("{0}" -f $_.$colLP).Trim() -ne '') -or
        ($colLPPF -and $_.$colLPPF -and ("{0}" -f $_.$colLPPF).Trim() -ne '')
    }
).Count } else { 0 }
$hasRate   = if ($colRate) { ($rows | Where-Object { $_.$colRate -and ("{0}" -f $_.$colRate).Trim() -ne '' }).Count } else { 0 }

$stockedMissingSku = if ($colSOHQty) { ($rows | Where-Object { $_.$colSOHQty -and ("{0}" -f $_.$colSOHQty).Trim() -ne '' -and ( -not $_.SKU -or $_.SKU.Trim() -eq '' ) }).Count } else { 0 }

$excludedPrefixes = ($rows | Where-Object { $_.SKU -and ( $_.SKU -like '800-*' -or $_.SKU -like '2000-*') }).Count

[PSCustomObject]@{
    File                    = $Path
    Rows                    = $total
    HasDemand               = $hasDemand
    HasSOH                  = $hasSOH
    HasLastPurchase         = $hasLP
    HasUnitRate             = $hasRate
    Stocked_Missing_SKU     = $stockedMissingSku
    ExcludedPrefixRows      = $excludedPrefixes
} | Format-List

# Optional: show a few rows that would violate the strict rule (should be none)
$violations = if ($colSOHQty) { $rows | Where-Object { $_.$colSOHQty -and ("{0}" -f $_.$colSOHQty).Trim() -ne '' -and ( -not $_.SKU -or $_.SKU.Trim() -eq '' ) } | Select-Object -First 5 } else { @() }
if ($violations.Count -gt 0) {
    Write-Host "\nExamples of stocked rows with missing SKU (should be 0 with strict WHERE):"
    $violations | Format-Table SKU,'soh.On_Hand_Qty','db.Avg_Demand_Used','base.Product_ID' -AutoSize
}