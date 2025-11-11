# Order Preparation in Zoho Analytics

Comprehensive guide to build the daily Order Prep dataset and dashboard using Zoho Analytics + Zoho Books data.

## Overview
Goal: A daily refreshed snapshot per SKU with:
- 24 months sales history
- Outstanding purchase order quantity
- Last purchase price/date/vendor
- Available stock & inventory value
- 6‑month average monthly demand
- Optional reorder metrics (lead time demand, safety stock, reorder point)

## Sections
1. OAuth & Environment Setup (US Data Center)
2. Schema Export & Workspace ID Troubleshooting
3. Query Table SQL Templates
4. Refresh Scheduling
5. Dashboard Assembly
6. Widget Deep-Link (Optional)
7. Validation Checklist
8. Common Errors & Fixes

---
## 1. OAuth & Environment Setup (US)
Scopes (minimum):
- `ZohoAnalytics.data.read`
- `ZohoAnalytics.metadata.read`

Create client (Self Client or Server-based) at https://api-console.zoho.com
Generate authorization code.
Exchange for tokens:
```pwsh
pwsh ./tools/diagnostics/zoho_token_exchange.ps1 `
  -ClientId "1000.CLIENTID" `
  -ClientSecret "CLIENT_SECRET" `
  -Code "1000.AUTH_CODE" `
```
Set environment variables (Zoho Finance Analytics runs on analytics.zoho.com, not analyticsapi):
```pwsh
$env:ZOHO_ANALYTICS_DOMAIN = 'https://analytics.zoho.com'
$env:ZOHO_ANALYTICS_WORKSPACE = '2755984000000494001'  # Zoho Finance Analytics workspace
$env:ZOHO_ANALYTICS_ORGID = '815316971'                # Correct Org ID for packaged workspace
$env:ZOHO_ANALYTICS_TOKEN = '<ACCESS_TOKEN>'           # Raw token
```
Refresh token when needed:
```pwsh
pwsh ./tools/diagnostics/zoho_refresh_token.ps1 -ClientId "1000.CLIENTID" -ClientSecret "CLIENT_SECRET" -RefreshToken "1000.REFRESH" -AccountsDomain com
$env:ZOHO_ANALYTICS_TOKEN = '<NEW_ACCESS_TOKEN>'
```

Mask tokens when printing:
```pwsh
$token = $env:ZOHO_ANALYTICS_TOKEN; if($token){ $token.Substring(0,6)+'...'+$token.Substring($token.Length-6) }
```

---
## 2. Schema Export & Workspace ID Troubleshooting
Run export:
```pwsh
pwsh ./tools/analytics/export-schema.ps1
```
Output: `tools/analytics/DATA_SCHEMA.out.json`

If `tables` / `views` come back empty:
- Verify Workspace ID (open Zoho Analytics directly, not via Zoho One wrapper).
- Reissue access token (INVALID_TICKET often cleared with fresh token).
- Confirm Org ID header: set `ZOHO_ANALYTICS_ORGID` (815316971 for this workspace).
- Try enumerating via views endpoint (script already falls back).

If persistent 400:
- Ensure scopes include metadata.
- Re-run token exchange (authorization code single-use).

---
## 3. Query Table SQL Templates
Replace placeholder table/column names where they differ.

### Automating Creation via API (Optional)

Instead of pasting each SQL manually, you can use `create-query-tables.ps1` with `query-tables.json`:

```pwsh
$env:ZOHO_ANALYTICS_DOMAIN='https://analytics.zoho.com'
$env:ZOHO_ANALYTICS_WORKSPACE='2755984000000494001'
$env:ZOHO_ANALYTICS_ORGID='815316971'
$env:ZOHO_ANALYTICS_TOKEN='<ACCESS_TOKEN>'
pwsh ./tools/analytics/create-query-tables.ps1 -ConfigPath ./tools/analytics/query-tables.json
```

Note: In Zoho Finance Analytics (managed workspace), modeling endpoints may intermittently return `7005 COMMON_INTERNAL_SERVER_ERROR`. When that occurs, create the Query Tables manually in the UI by pasting the SQL below. Required scopes for programmatic creation (when available): `ZohoAnalytics.metadata.read`, `ZohoAnalytics.metadata.create`, `ZohoAnalytics.data.read`.

### 3.1 Sales last 24 months

Screenshot review: `Invoice Items` shows headers `Item ID`, `Invoice ID`, `Item Name`, `Quantity`, `Total (BCY)`, `Sub Total (BCY)` (no `Item SKU`, no line unit price). We therefore:
1. Use `Item ID` as product key.
2. Pull SKU only from `Items` (fallback to either `Item SKU` or `SKU`).
3. Use monetary extended line total directly (prefer `Total (BCY)`; fallback `Sub Total (BCY)`).

Recommended query:

```sql
CREATE QUERY TABLE qt_sales_24m AS
SELECT
    COALESCE(i."Item SKU", i."SKU") AS SKU,
    li."Item ID" AS Product_ID,
    date_format(inv."Invoice Date", '%Y-%m') AS Month_Year,
    SUM(li.Quantity) AS Total_Quantity,
    SUM(COALESCE(li."Total (BCY)", li."Sub Total (BCY)")) AS Net_Sales
FROM "Invoice Items" li
JOIN "Invoices" inv ON inv."Invoice ID" = li."Invoice ID"
LEFT JOIN "Items" i ON i."Item ID" = li."Item ID"
WHERE inv."Invoice Date" >= dateadd('month', -24, currentdate())
GROUP BY COALESCE(i."Item SKU", i."SKU"), li."Item ID", Month_Year;
```

Dialect alternate:

```sql
WHERE inv."Invoice Date" >= add_months(currentdate(), -24)
```

If only one monetary column exists, replace the `SUM(COALESCE(...))` with that column alone. If your workspace exposes a generic `Amount` column instead of the BCY fields:

```sql
SUM(li."Amount") AS Net_Sales
```

Legacy variants using line-level `Item SKU` retained for reference (use only if it appears):

```sql
SELECT li."Item SKU" AS SKU, li."Item ID" AS Product_ID, ... GROUP BY li."Item SKU", li."Item ID", Month_Year
```

Fallback (no date_format / add_months functions available)

If your engine flags `date_format`, `add_months`, or `currentdate()` as unsupported, use plain YEAR/MONTH extraction and a 2-year cutoff:

```sql
CREATE QUERY TABLE qt_sales_24m AS
SELECT
  i."SKU" AS SKU,
  li."Item ID" AS Product_ID,
  -- Build a YYYY-MM string manually
  (CAST(YEAR(inv."Invoice Date") AS VARCHAR) || '-' || LPAD(CAST(MONTH(inv."Invoice Date") AS VARCHAR), 2, '0')) AS Month_Year,
  SUM(li.Quantity) AS Total_Quantity,
  SUM(COALESCE(li."Total (BCY)", li."Sub Total (BCY)")) AS Net_Sales
FROM "Invoice Items" li
JOIN "Invoices" inv ON inv."Invoice ID" = li."Invoice ID"
LEFT JOIN "Items" i ON i."Item ID" = li."Item ID"
WHERE inv."Invoice Date" >= dateadd('yy', -2, currentdate())
GROUP BY i."SKU", li."Item ID", YEAR(inv."Invoice Date"), MONTH(inv."Invoice Date");
```

If `LPAD` is not available, you can zero-pad with CASE:

```sql
CASE WHEN MONTH(inv."Invoice Date") < 10 THEN '0' || CAST(MONTH(inv."Invoice Date") AS VARCHAR) ELSE CAST(MONTH(inv."Invoice Date") AS VARCHAR) END
```

Then replace the Month_Year expression accordingly.

### 3.2 Outstanding purchase orders

```sql
-- Open-status approximation (no line-level received qty available)
CREATE QUERY TABLE qt_outstanding_po AS
SELECT
  COALESCE(i."Item SKU", i."SKU") AS SKU,
  poi."Item ID" AS Product_ID,
  SUM(CASE WHEN po."Purchase Order Status" IN ('Billed','Closed')
       THEN 0 ELSE poi.Quantity END) AS Outstanding_Qty
FROM "Purchase Order Items" poi
JOIN "Purchase Orders" po ON po."Purchase Order ID" = poi."Purchase Order ID"
LEFT JOIN "Items" i ON i."Item ID" = poi."Item ID"
GROUP BY COALESCE(i."Item SKU", i."SKU"), poi."Item ID";
```
If GREATEST is unsupported in your dialect:

```sql
SUM(CASE WHEN (pli."Quantity Ordered" - pli."Quantity Received") > 0 THEN (pli."Quantity Ordered" - pli."Quantity Received") ELSE 0 END)
```

If a received quantity field DOES exist (e.g., `poi."Quantity Received"` or `poi."Received Quantity"`), prefer the more precise version:

```sql
CREATE QUERY TABLE qt_outstanding_po AS
SELECT
    COALESCE(i."Item SKU", i."SKU") AS SKU,
    poi."Item ID" AS Product_ID,
    SUM(CASE
          WHEN po."Purchase Order Status" IN ('Billed','Closed') THEN 0
          ELSE GREATEST(poi.Quantity - COALESCE(poi."Quantity Received", poi."Received Quantity", 0), 0)
        END) AS Outstanding_Qty
FROM "Purchase Order Items" poi
JOIN "Purchase Orders" po ON po."Purchase Order ID" = poi."Purchase Order ID"
LEFT JOIN "Items" i ON i."Item ID" = poi."Item ID"
GROUP BY COALESCE(i."Item SKU", i."SKU"), poi."Item ID";
```

If receipts are tracked in a separate table at the PO level only (e.g., `"Purchase Receive"`) without item detail, reliable per-item outstanding cannot be computed directly; retain the ordered-as-outstanding approximation above.

If neither `Item SKU` nor `SKU` exists in Items use an alternate item identifier (e.g., Item_Name) for grouping, but note higher risk of name changes.

```sql
CREATE QUERY TABLE qt_outstanding_po AS
SELECT
    i."SKU" AS SKU,
    pli."Item ID" AS Product_ID,
    SUM(GREATEST(pli."Quantity Ordered" - pli."Quantity Received", 0)) AS Outstanding_Qty
FROM "Purchase Order Items" pli
JOIN "Purchase Orders" po
  ON po."Purchase Order ID" = pli."Purchase Order ID"
LEFT JOIN "Items" i
  ON i."Item ID" = pli."Item ID"
WHERE po."Purchase Order Status" NOT IN ('Billed','Closed')
GROUP BY i."SKU", pli."Item ID";
```

Precise variant using Purchase Receive Items (+ age cutoffs)

The Finance Analytics connector now exposes three receive-related tables with the following key columns:
- "Purchase Receive Items": `Purchase Receive ID`, `Purchase Order Item ID`, `Item ID`, `Quantity Received`, `Created Time`
- "Purchase Receive": `Purchase Receive ID`, `Purchase Order ID`, `Date`, `Created Time`
- "Purchase Receive History": aggregated counts (not used for joins)

Because "Purchase Order Items" typically does not expose a "Purchase Order Item ID" column in this workspace, join the receive lines to the receive header to recover `Purchase Order ID`, then aggregate by `(Purchase Order ID, Item ID)` to compare against ordered quantity by the same composite key. This implements your business rules:
- Exclude any PO that has been partially received and is older than 3 months.
- Exclude any PO that is older than 6 months (regardless of receive status).

```sql
-- Precise outstanding using receive lines via receive header + age filters
CREATE QUERY TABLE qt_outstanding_po_precise AS
WITH ordered AS (
  SELECT
    poi."Purchase Order ID" AS PO_ID,
    poi."Item ID"           AS Item_ID,
    SUM(poi.Quantity)       AS Ordered_Qty
  FROM "Purchase Order Items" poi
  GROUP BY poi."Purchase Order ID", poi."Item ID"
),
recv AS (
  SELECT
    pr."Purchase Order ID" AS PO_ID,
    rli."Item ID"          AS Item_ID,
    SUM(rli."Quantity Received") AS Received_Qty,
    MAX(rli."Created Time")      AS Last_Receive_Time
  FROM "Purchase Receive Items" rli
  JOIN "Purchase Receive" pr
    ON pr."Purchase Receive ID" = rli."Purchase Receive ID"
  GROUP BY pr."Purchase Order ID", rli."Item ID"
),
by_po_item AS (
  SELECT
    o.PO_ID,
    o.Item_ID,
    GREATEST(o.Ordered_Qty - COALESCE(r.Received_Qty, 0), 0) AS Outstanding_By_PO_Item,
    COALESCE(r.Received_Qty, 0) AS Received_Qty
  FROM ordered o
  LEFT JOIN recv r
    ON r.PO_ID = o.PO_ID AND r.Item_ID = o.Item_ID
)
SELECT
  COALESCE(i."Item SKU", i."SKU") AS SKU,
  b.Item_ID AS Product_ID,
  SUM(CASE
        WHEN po."Purchase Order Status" IN ('Billed','Closed') THEN 0
        ELSE b.Outstanding_By_PO_Item
      END) AS Outstanding_Qty
FROM by_po_item b
JOIN "Purchase Orders" po
  ON po."Purchase Order ID" = b.PO_ID
LEFT JOIN "Items" i
  ON i."Item ID" = b.Item_ID
WHERE po."Purchase Order Status" NOT IN ('Billed','Closed')
  AND po."Purchase Order Date" >= dateadd('month', -6, currentdate())
  AND NOT (
        po."Purchase Order Date" < dateadd('month', -3, currentdate())
    AND  b.Received_Qty > 0
  )
GROUP BY COALESCE(i."Item SKU", i."SKU"), b.Item_ID;
```

Dialect fallbacks:
- If `dateadd('month', ...)` isn’t supported, use `add_months(currentdate(), -6)` and `add_months(currentdate(), -3)`.
- If neither function exists, filter by static cutoff dates (e.g., `>= '2025-05-08'`) adjusted monthly.
- If your engine doesn’t support `GREATEST`, replace with a CASE expression:
  `CASE WHEN (o.Ordered_Qty - COALESCE(r.Received_Qty,0)) > 0 THEN (o.Ordered_Qty - COALESCE(r.Received_Qty,0)) ELSE 0 END`.

```sql
-- Example fallback using add_months
WHERE po."Purchase Order Status" NOT IN ('Billed','Closed')
  AND po."Purchase Order Date" >= add_months(currentdate(), -6)
  AND NOT (
        po."Purchase Order Date" < add_months(currentdate(), -3)
    AND  b.Received_Qty > 0
  )
```

### 3.3 Latest purchase line

```sql
CREATE QUERY TABLE qt_last_purchase AS
SELECT
  SKU,
  Product_ID,
  "Purchase Order Date" AS Last_Purchase_Date,
  Item_Price AS Last_Purchase_Price,
  Vendor_Name
FROM (
  SELECT
    COALESCE(i."Item SKU", i."SKU") AS SKU,
    pli."Item ID" AS Product_ID,
    po."Purchase Order Date",
    -- Derive unit price from extended total if no explicit Item Price column
    CASE
      WHEN pli.Quantity IS NOT NULL AND pli.Quantity <> 0 THEN
        COALESCE(pli."Total (BCY)", pli."Sub Total (BCY)") / pli.Quantity
      ELSE NULL
    END AS Item_Price,
    po."Vendor Name" AS Vendor_Name,
    ROW_NUMBER() OVER (PARTITION BY pli."Item ID" ORDER BY po."Purchase Order Date" DESC) AS rn
  FROM "Purchase Order Items" pli
  JOIN "Purchase Orders" po ON po."Purchase Order ID" = pli."Purchase Order ID"
  LEFT JOIN "Items" i ON i."Item ID" = pli."Item ID"
) t
WHERE rn = 1;
```

If "Item SKU" is unavailable, use Items.SKU in the subquery and keep partitioning by Item ID:

```sql
CREATE QUERY TABLE qt_last_purchase AS
SELECT
  SKU,
  Product_ID,
  "Purchase Order Date" AS Last_Purchase_Date,
  Item_Price AS Last_Purchase_Price,
  Vendor_Name
FROM (
  SELECT
    COALESCE(i."Item SKU", i."SKU") AS SKU,
    pli."Item ID" AS Product_ID,
    po."Purchase Order Date",
    CASE
      WHEN pli.Quantity IS NOT NULL AND pli.Quantity <> 0 THEN
        COALESCE(pli."Total (BCY)", pli."Sub Total (BCY)") / pli.Quantity
      ELSE NULL
    END AS Item_Price,
    po."Vendor Name" AS Vendor_Name,
    ROW_NUMBER() OVER (PARTITION BY pli."Item ID" ORDER BY po."Purchase Order Date" DESC) AS rn
  FROM "Purchase Order Items" pli
  JOIN "Purchase Orders" po ON po."Purchase Order ID" = pli."Purchase Order ID"
  LEFT JOIN "Items" i ON i."Item ID" = pli."Item ID"
) t
WHERE rn = 1;
```

If you prefer to store the extended amount instead of derived unit price, add `COALESCE(pli."Total (BCY)", pli."Sub Total (BCY)") AS Last_Purchase_Extended` to the inner SELECT and surface it in the outer SELECT.

### 3.4 Average demand (6 months)

```sql
CREATE QUERY TABLE qt_avg_demand_6m AS
SELECT
  SKU,
  Product_ID,
  SUM(Total_Quantity) / 6.0 AS AvgMonthlyQty_6m
FROM qt_sales_24m
WHERE Month_Year >= date_format(dateadd('month', -6, currentdate()), '%Y-%m')
GROUP BY SKU, Product_ID;
```

Note: If you changed Net_Sales to use li."Amount", the Avg demand logic is unaffected (it only uses Total_Quantity).

### 3.5 Item snapshot

```sql
CREATE QUERY TABLE qt_item_snapshot AS
SELECT
    COALESCE(i."Item SKU", i."SKU") AS SKU,
    i."Item ID"  AS Product_ID,
    i.Item_Name,
    i.Available_Stock,
    i.Cost,
    -- Additional attributes carried through for reporting
    i."Supplier Code" AS Supplier_Code,
    i."ENG Description" AS ENG_Description,
    i."Alternate Supplier" AS Alternate_Supplier,
    i."Vehicles" AS Vehicles,
    i."Tipo de Cliente" AS Tipo_de_Cliente,
    (i.Available_Stock * i.Cost) AS Inventory_Value,
    COALESCE(o.Outstanding_Qty, 0) AS Outstanding_Qty,
    lp.Last_Purchase_Price,
    lp.Last_Purchase_Date,
    lp.Vendor_Name,
    ad.AvgMonthlyQty_6m
FROM "Items" i
LEFT JOIN qt_outstanding_po_precise o
  ON o.SKU = COALESCE(i."Item SKU", i."SKU") AND o.Product_ID = i."Item ID"
LEFT JOIN qt_last_purchase lp
  ON lp.SKU = COALESCE(i."Item SKU", i."SKU") AND lp.Product_ID = i."Item ID"
LEFT JOIN qt_avg_demand_6m ad
  ON ad.SKU = COALESCE(i."Item SKU", i."SKU") AND ad.Product_ID = i."Item ID";
```

### 3.6 Extended snapshot with reorder metrics (optional)

```sql
CREATE QUERY TABLE qt_item_snapshot_plus AS
SELECT
    s.*,
    (s.AvgMonthlyQty_6m / 30.0) AS AvgDailyQty_6m,
    (s.AvgMonthlyQty_6m / 30.0) * COALESCE(cfg.Lead_Time_Days, 15) AS LeadTimeDemand,
    ((s.AvgMonthlyQty_6m / 30.0) * COALESCE(cfg.Lead_Time_Days, 15)) + COALESCE(cfg.Safety_Stock, 0) AS Reorder_Point
FROM qt_item_snapshot s
LEFT JOIN "Reorder Config" cfg
  ON cfg.SKU = s.SKU;
```
Skip if no config table exists yet.

### 3.7 Using workspace variables for date cutoffs (recommended)
Instead of hard-coding dates in WHERE clauses, define workspace/User Variables once and reference them in queries. This avoids editing SQL each month.

Create three Date variables in Zoho Analytics (Workspace Settings → Variables):

- SALES_24M_START = 2023-11-01 (first day of the 24-month window)
- PO_6M_START = 2025-05-01 (first day inside the 6-month window)
- PO_3M_PARTIAL_START = 2025-08-01 (first day inside the 3-month window)

Then, update the SQL like so:

- qt_sales_24m (static literal → variable)

```sql
WHERE r.Invoice_Date >= ${SALES_24M_START}
```

- qt_outstanding_po_precise (both literals → variables)

```sql
WHERE po."Purchase Order Status" NOT IN ('Billed','Closed')
  AND po."Purchase Order Date" >= ${PO_6M_START}
  AND NOT (
        po."Purchase Order Date" < ${PO_3M_PARTIAL_START}
    AND  b.Received_Qty > 0
  )
```

Notes:

- Define these variables with type Date so you don’t need casts or parsing; the engine treats `${VARNAME}` as a date literal.
- If your workspace only allows Text variables, wrap once with a cast supported by your engine (e.g., `CAST(${SALES_24M_START} AS DATE)`), but prefer Date-type variables to avoid unsupported function errors.
- Monthly maintenance: advance all three values by one month; no SQL changes needed.

#### If a Date variable type is NOT available
Some managed Finance Analytics workspaces only offer: Plain Text, Number, Positive Number, Decimal Number, Currency, Percentage. Use one of the following fallback patterns:

Option A (Plain Text YYYY-MM-DD strings)
1. Create Plain Text variables:
  - SALES_24M_START_STR = 2023-11-01
  - PO_6M_START_STR = 2025-05-01
  - PO_3M_PARTIAL_START_STR = 2025-08-01
2. Reference directly (most engines auto-cast):
```sql
WHERE r.Invoice_Date >= ${SALES_24M_START_STR}
```
If the engine errors (treats value as identifier), wrap in quotes at usage time:
```sql
WHERE r.Invoice_Date >= '${SALES_24M_START_STR}'
```
Or store the value WITH quotes inside the variable (e.g., value = '2023-11-01') and reference unquoted.

Option B (Numeric YearMonth integer)
1. Create Number variables:
  - SALES_24M_START_YEARMON = 202311
  - PO_6M_START_YEARMON = 202505
  - PO_3M_PARTIAL_START_YEARMON = 202508
2. Compare using YEAR/MONTH arithmetic already supported in your saved queries:
```sql
WHERE (YEAR(r.Invoice_Date)*100 + MONTH(r.Invoice_Date)) >= ${SALES_24M_START_YEARMON}
```
3. Outstanding PO filter:
```sql
WHERE (YEAR(po."Purchase Order Date")*100 + MONTH(po."Purchase Order Date")) >= ${PO_6M_START_YEARMON}
  AND NOT (
      (YEAR(po."Purchase Order Date")*100 + MONTH(po."Purchase Order Date")) < ${PO_3M_PARTIAL_START_YEARMON}
   AND  b.Received_Qty > 0
  )
```

Monthly rollover checklist (run on 1st of each month):
- Increment each *_START_STR date by one month (preserve day = 01).
- Increment each *_YEARMON by +1 normally, except December → January (e.g., 202512 → 202601).
- Keep both representations in sync if you use both.

Optional PowerShell helper (prints next YearMonth and first-of-month date):

```pwsh
$today = Get-Date
# 24 month start (first day 24 months back)
$sales24Start = (Get-Date -Day 1).AddMonths(-24)
Write-Host ('SALES_24M_START_STR = {0:yyyy-MM}-01' -f $sales24Start)
Write-Host ('SALES_24M_START_YEARMON = {0:yyyyMM}' -f $sales24Start)

# 6 month and 3 month anchors
$po6Start = (Get-Date -Day 1).AddMonths(-6)
$po3Start = (Get-Date -Day 1).AddMonths(-3)
Write-Host ('PO_6M_START_STR = {0:yyyy-MM}-01' -f $po6Start)
Write-Host ('PO_6M_START_YEARMON = {0:yyyyMM}' -f $po6Start)
Write-Host ('PO_3M_PARTIAL_START_STR = {0:yyyy-MM}-01' -f $po3Start)
Write-Host ('PO_3M_PARTIAL_START_YEARMON = {0:yyyyMM}' -f $po3Start)
```
Adapt for the 6M / 3M variables by replacing -24 with -6 and -3 respectively.

Recommendation: Prefer Option A (plain text ISO dates) first; fall back to Option B only if comparisons on plain text fail.

---
## 4. Refresh Scheduling
Order: run upstream tables first (sales → outstanding_po → last_purchase → avg_demand → snapshot → snapshot_plus). Set all to daily 06:00 local time. If near real-time needed, increase frequency for `qt_outstanding_po` and `qt_last_purchase` (hourly) and rebuild snapshot afterward.

---
## 5. Dashboard Assembly
Widgets:
- KPI: Available_Stock, Inventory_Value, Outstanding_Qty, AvgMonthlyQty_6m, Last_Purchase_Price.
- Line Chart: Month_Year vs Total_Quantity (filter SKU) from qt_sales_24m.
- Table: qt_item_snapshot_plus (sortable by Reorder_Point or Outstanding_Qty).
- Filters: SKU (searchable), Vendor_Name, Month range.
Conditional formatting examples:
- Highlight Outstanding_Qty > 0 in orange.
- Highlight Available_Stock < LeadTimeDemand in red.

---
## 6. Widget Deep-Link (Optional)
From Zoho Books widget, construct link:
```
https://analytics.zoho.com/open-view/<WORKSPACE_INTERNAL_ID>/<DASHBOARD_ID>?SKU=${sku}
```
Capture actual dashboard URL once created; append query parameter recognized by your dashboard filter (create a user variable or filter mapped to SKU).

---
## 7. Validation Checklist
For 2–3 SKUs:
- Sales totals last month match Zoho Books widget output.
- Outstanding quantity equals (Ordered − Received) excluding Billed/Closed POs.
- Last purchase price/date matches the most recent valid PO line.
- Inventory value = Available_Stock * Cost.
- AvgMonthlyQty_6m approximates manual average (tolerate minor rounding).
Document any systematic differences (currency conversion, partial receipts timing).

---
## 8. Common Errors & Fixes
| Symptom | Cause | Fix |
|---------|-------|-----|
| INVALID_TICKET | Stale or already-used auth code | Regenerate auth code & exchange again |
| 400 on /tables | Endpoint not supported / workspace mismatch | Use analytics.zoho.com and /views?type=TABLE (script adapts) |
| Empty schema | Wrong workspace ID from Zoho One wrapper | Open Analytics directly; capture ID from native URL |
| 7005 COMMON_INTERNAL_SERVER_ERROR on creation/columns | Packaged workspace restrictions or transient server issue | Create query tables manually in UI; if persistent, try owner token or contact support |
| Unknown column in SQL | Label vs internal name mismatch | Open table design; use internal name shown in column properties |
| Window function error | Plan tier or dialect restriction | Replace ROW_NUMBER with MAX(date) subquery join |
| Timezone drift in daily refresh | Workspace timezone mis-set | Check Workspace Settings > Locale |
| Slow dashboard | Too many heavy filters & formula columns | Precompute metrics in snapshot tables |

---
## 9. Next Enhancements
- Currency normalization (CRC → USD) using Exchange Rate column.
- Safety stock formula: `Z * sqrt(LeadTimeVariance + DemandVariance)` if data available.
- Aging report for last purchase > X days.
- Rolling 3‑month trend columns.

---
## 10. Maintenance
Monthly:
- Re-verify token validity; refresh if expiring frequently.
- Spot-check 1 SKU end-to-end.
Quarterly:
- Add/remove SKU attributes (e.g., category) for grouping.
- Optimize dashboard by hiding rarely used columns.

---
## 11. Quick Commands Reference
```pwsh
# Exchange auth code
pwsh ./tools/diagnostics/zoho_token_exchange.ps1 -ClientId "1000.ID" -ClientSecret "SECRET" -Code "1000.CODE" -AccountsDomain com

# Refresh token
pwsh ./tools/diagnostics/zoho_refresh_token.ps1 -ClientId "1000.ID" -ClientSecret "SECRET" -RefreshToken "1000.REFRESH" -AccountsDomain com

# Run schema export
pwsh ./tools/analytics/export-schema.ps1

# Automate query table creation
pwsh ./tools/analytics/create-query-tables.ps1 -ConfigPath ./tools/analytics/query-tables.json
```

---
## 12. Assumptions & Placeholders
Replace these if different in your workspace:
- "Invoice Items" / "Invoices"
- "Purchase Order Items" / "Purchase Orders"
- Column names used in SQL: "Invoice Date", "Purchase Order Date", "Quantity Ordered", "Quantity Received", Cost, Available_Stock, "Item SKU" | "SKU" (Items), "Item ID", "Total (BCY)" | "Sub Total (BCY)"
- Items attributes (optional but supported in snapshot): "Supplier Code", "ENG Description", "Alternate Supplier", "Vehicles", "Tipo de Cliente"

If your workspace uses alternative names (e.g., `Invoice_Date` or `Qty_Ordered`), adjust SQL accordingly.

---
## 13. Support Notes
Keep tokens out of commits. If you accidentally commit, rotate client secret and regenerate tokens. Prefer using environment variables only during active sessions.

---
**End of Guide**
