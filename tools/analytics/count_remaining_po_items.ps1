param(
  [string]$PoiPath = "c:/Users/eprit/Projects/Pantera/order-prep-tool/data/Zoho_Finance_Analytics_partial_export_Nov2025/Purchase_Order_Items.csv",
  [string]$PrPath = "c:/Users/eprit/Projects/Pantera/order-prep-tool/data/Zoho_Finance_Analytics_partial_export_Nov2025/Purchase_Receive.csv"
)

$ErrorActionPreference = 'Stop'

$poi = Import-Csv -Path $PoiPath
$pr  = Import-Csv -Path $PrPath

$received = $pr.'Purchase Order ID' | Sort-Object -Unique
$remaining = $poi | Where-Object { $received -notcontains $_.'Purchase Order ID' }

[pscustomobject]@{
  PoiRows                = $poi.Count
  UniqueReceivedPOs      = $received.Count
  RemainingItemRows      = $remaining.Count
} | Format-List
