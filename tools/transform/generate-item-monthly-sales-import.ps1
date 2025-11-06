param(
    [string]$InputPath = "${PSScriptRoot}\..\..\webclient\data\SalesHistory_Updated_Oct2025.csv",
    [string]$OutputPath = "${PSScriptRoot}\out\item_monthly_sales_import.csv",
    [string]$DefaultCurrency = "USD",
    [switch]$IncludeMonthDate
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# Ensure output folder exists
$outDir = [System.IO.Path]::GetDirectoryName($OutputPath)
if (-not [string]::IsNullOrWhiteSpace($outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}

# Month regex YYYY-MM
$monthRegex = '^(?<year>\d{4})-(?<month>0[1-9]|1[0-2])$'
# Use a Zoho-friendly DateTime format: yyyy-MM-dd HH:mm (no 'T' or 'Z')
$nowZoho = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')

if (-not (Test-Path -Path $InputPath)) {
    throw "Input CSV not found: $InputPath"
}

# Import source CSV
$rows = Import-Csv -Path $InputPath -Delimiter ','

function Get-Prop {
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string[]]$Names
    )
    foreach ($n in $Names) {
        if ($Row.PSObject.Properties.Match($n).Count -gt 0) {
            $v = $Row.$n
            if ($null -ne $v -and -not [string]::IsNullOrWhiteSpace([string]$v)) { return $v }
        }
    }
    return $null
}

$mapped = foreach ($r in $rows) {
    # Header normalization with fallbacks
    $itemId    = Get-Prop -Row $r -Names @('Item_ID','Product ID','Product_ID')
    $sku       = Get-Prop -Row $r -Names @('Item_SKU','SKU')
    $itemName  = Get-Prop -Row $r -Names @('Item_Name','Item Name','Name')
    $monthYear = Get-Prop -Row $r -Names @('Month_Year','MonthYear','Month-Year')
    $totalQty  = Get-Prop -Row $r -Names @('Total_Quantity','TotalQuantity','Qty')
    $netSales  = Get-Prop -Row $r -Names @('Net_Sales','NetSales','Amount')
    $currency  = Get-Prop -Row $r -Names @('Currency','Currency Code','Currency_Code')
    if ([string]::IsNullOrWhiteSpace($currency)) { $currency = $DefaultCurrency }

    if ([string]::IsNullOrWhiteSpace($itemId) -or [string]::IsNullOrWhiteSpace($monthYear)) { continue }

    # Validate month format
    if (-not ($monthYear -match $monthRegex)) { continue }

    $monthDate = "{0}-{1}-01" -f $Matches['year'],$Matches['month']

    [PSCustomObject]@{
        key            = "$itemId-$monthYear"
        item_id        = $itemId
        sku            = $sku
        item_name      = $itemName
        month_year     = $monthYear
        month_date     = $monthDate
        total_quantity = $totalQty
        net_sales      = $netSales
        currency       = $currency
        last_updated   = $nowZoho
    }
}

# By default we export both month_year (YYYY-MM) and month_date (YYYY-MM-01).
# If consumer wants to exclude month_date, they can delete the column or ignore during import.
# Optionally, only include month_date if switch is set (keeps file smaller if desired)
if ($IncludeMonthDate) {
    $mapped | Select-Object key,item_id,sku,item_name,month_year,month_date,total_quantity,net_sales,currency,last_updated |
        Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
} else {
    $mapped | Select-Object key,item_id,sku,item_name,month_year,month_date,total_quantity,net_sales,currency,last_updated |
        Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
}

Write-Host "Created import CSV:" $OutputPath