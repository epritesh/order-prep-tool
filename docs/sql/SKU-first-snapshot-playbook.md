# SKU-First Item Snapshot Playbook

Author: AI assistant
Last Updated: 2025-11-08

## Goal
Canonical set of Zoho Analytics Query Table (QT) SQL snippets to build an item snapshot using **SKU as the source of truth**, avoiding Product_ID vs Product ID header drift. Copy blocks directly into the Zoho Analytics SQL editor.

## Overview
We normalize every table to a single `SKU` key. Where a source only has `Product_ID`, we bridge Product_ID -> SKU using inventory (preferred) then sales fallback. After the bridge, all joins aggregate at SKU level.

Data sources (CSV/QT headers confirmed):
- `qt_sales_24m`: Product_ID, SKU, Total_Quantity, Net_Sales
- `Inventory_Items_Export_2025-11-08`: Item ID ("Item ID"), SKU (may include blanks)
- `qt_demand_backfill_v2`: Product_ID, Avg_Demand_Used, Avg_Demand_6M
- `qt_stock_on_hand_final_v3`: Product_ID, On_Hand_Qty, On_Hand_Source
- `qt_last_purchase`: Product_ID, SKU, Last_Purchase_Price
- `qt_last_purchase_fallback`: Product_ID, Last_Purchase_Price
- `qt_items_fallback`: Product_ID, Available_Stock, Cost_Fallback (no SKU)

## 1. Sales Base Probe
```sql
SELECT
  s.Product_ID,
  MAX(s.SKU)            AS Sales_SKU,
  SUM(s.Total_Quantity) AS Sales_24M_Qty,
  SUM(s.Net_Sales)      AS Sales_24M_Net
FROM qt_sales_24m s
GROUP BY s.Product_ID
ORDER BY s.Product_ID
LIMIT 20
```
Should return rows with `Sales_SKU` blank where missing in sales.

## 2. Inventory Base Probe
```sql
WITH inventory_base AS (
  SELECT
    ie."Item ID" AS Product_ID,
    MAX(ie.SKU)  AS Item_SKU
  FROM "Inventory_Items_Export_2025-11-08" ie
  GROUP BY ie."Item ID"
)
SELECT Product_ID, Item_SKU
FROM inventory_base
WHERE Item_SKU IS NOT NULL AND TRIM(Item_SKU) <> ''
ORDER BY Product_ID
LIMIT 20;
```

## 3. Product -> SKU Bridge + Sales Aggregation
```sql
WITH
sales_base AS (
  SELECT
    s.Product_ID,
    TRIM(MAX(s.SKU))      AS Sales_SKU,
    SUM(s.Total_Quantity) AS Sales_24M_Qty,
    SUM(s.Net_Sales)      AS Sales_24M_Net
  FROM qt_sales_24m s
  GROUP BY s.Product_ID
),
inventory_base AS (
  SELECT
    ie."Item ID" AS Product_ID,
    TRIM(MAX(ie.SKU))     AS Item_SKU
  FROM "Inventory_Items_Export_2025-11-08" ie
  GROUP BY ie."Item ID"
),
sku_bridge AS (
  SELECT
    sb.Product_ID,
    CASE
      WHEN inventory_base.Item_SKU IS NOT NULL AND TRIM(inventory_base.Item_SKU) <> '' THEN TRIM(inventory_base.Item_SKU)
      WHEN sb.Sales_SKU IS NOT NULL AND TRIM(sb.Sales_SKU) <> '' THEN TRIM(sb.Sales_SKU)
      ELSE NULL
    END AS SKU
  FROM sales_base sb
  LEFT JOIN inventory_base
    ON CONCAT('', sb.Product_ID) = CONCAT('', inventory_base.Product_ID)
)
SELECT *
FROM sku_bridge
WHERE SKU IS NOT NULL AND TRIM(SKU) <> ''
ORDER BY SKU
LIMIT 50;
```

## 4. Aggregate All Sources by SKU
```sql
WITH
sales_base AS (
  SELECT
    s.Product_ID,
    TRIM(MAX(s.SKU))      AS Sales_SKU,
    SUM(s.Total_Quantity) AS Sales_24M_Qty,
    SUM(s.Net_Sales)      AS Sales_24M_Net
  FROM qt_sales_24m s
  GROUP BY s.Product_ID
),
inventory_base AS (
  SELECT
    ie."Item ID" AS Product_ID,
    TRIM(MAX(ie.SKU))     AS Item_SKU
  FROM "Inventory_Items_Export_2025-11-08" ie
  GROUP BY ie."Item ID"
),
sku_bridge AS (
  SELECT
    sb.Product_ID,
    CASE
      WHEN inventory_base.Item_SKU IS NOT NULL AND TRIM(inventory_base.Item_SKU) <> '' THEN TRIM(inventory_base.Item_SKU)
      WHEN sb.Sales_SKU IS NOT NULL AND TRIM(sb.Sales_SKU) <> '' THEN TRIM(sb.Sales_SKU)
      ELSE NULL
    END AS SKU,
    sb.Sales_24M_Qty,
    sb.Sales_24M_Net
  FROM sales_base sb
  LEFT JOIN inventory_base
    ON CONCAT('', sb.Product_ID) = CONCAT('', inventory_base.Product_ID)
),
sales_by_sku AS (
  SELECT
    b.SKU,
    SUM(b.Sales_24M_Qty) AS Sales_24M_Qty,
    SUM(b.Sales_24M_Net) AS Sales_24M_Net
  FROM sku_bridge b
  WHERE b.SKU IS NOT NULL AND TRIM(b.SKU) <> ''
  GROUP BY b.SKU
),
demand_by_sku AS (
  SELECT
    b.SKU,
    MAX(db.Avg_Demand_Used) AS Avg_Demand_Used,
    MAX(db.Avg_Demand_6M)   AS Avg_Demand_6M
  FROM sku_bridge b
  LEFT JOIN qt_demand_backfill_v2 db
    ON CONCAT('', b.Product_ID) = CONCAT('', db.Product_ID)
  WHERE b.SKU IS NOT NULL AND TRIM(b.SKU) <> ''
  GROUP BY b.SKU
),
soh_by_sku AS (
  SELECT
    b.SKU,
    MAX(soh.On_Hand_Qty)    AS On_Hand_Qty,
    MAX(soh.On_Hand_Source) AS On_Hand_Source
  FROM sku_bridge b
  LEFT JOIN qt_stock_on_hand_final_v3 soh
    ON CONCAT('', b.Product_ID) = CONCAT('', soh.Product_ID)
  WHERE b.SKU IS NOT NULL AND TRIM(b.SKU) <> ''
  GROUP BY b.SKU
),
last_price_by_sku AS (
  SELECT
    b.SKU,
    MAX(COALESCE(lp.Last_Purchase_Price, lpf.Last_Purchase_Price)) AS Last_Purchase_Price
  FROM sku_bridge b
  LEFT JOIN qt_last_purchase lp
    ON CONCAT('', b.Product_ID) = CONCAT('', lp.Product_ID)
  LEFT JOIN qt_last_purchase_fallback lpf
    ON CONCAT('', b.Product_ID) = CONCAT('', lpf.Product_ID)
  WHERE b.SKU IS NOT NULL AND TRIM(b.SKU) <> ''
  GROUP BY b.SKU
),
items_fallback_by_sku AS (
  SELECT
    b.SKU,
    MAX(itf.Available_Stock)  AS Available_Stock,
    MAX(itf.Cost_Fallback)    AS Cost_Fallback
  FROM sku_bridge b
  LEFT JOIN qt_items_fallback itf
    ON CONCAT('', b.Product_ID) = CONCAT('', itf.Product_ID)
  WHERE b.SKU IS NOT NULL AND TRIM(b.SKU) <> ''
  GROUP BY b.SKU
),
enriched AS (
  SELECT
    sb.SKU,
    sb.Sales_24M_Qty,
    sb.Sales_24M_Net,
    dbs.Avg_Demand_Used,
    dbs.Avg_Demand_6M,
    soh.On_Hand_Qty,
    soh.On_Hand_Source,
    lp.Last_Purchase_Price,
    itfb.Available_Stock,
    itfb.Cost_Fallback,
    CASE
      WHEN dbs.Avg_Demand_Used > 0 THEN soh.On_Hand_Qty / dbs.Avg_Demand_Used
      ELSE NULL
    END AS Coverage_Months,
    CASE
      WHEN dbs.Avg_Demand_Used > 0 AND COALESCE(soh.On_Hand_Qty,0) < dbs.Avg_Demand_Used THEN 'ELIGIBLE'
      ELSE 'NOT_ELIGIBLE'
    END AS Reorder_Eligibility,
    CASE
      WHEN dbs.Avg_Demand_Used > 0 AND COALESCE(soh.On_Hand_Qty,0) < dbs.Avg_Demand_Used THEN 1
      ELSE 0
    END AS Reorder_Flag,
    CASE
      WHEN dbs.Avg_Demand_Used > 0 THEN GREATEST((dbs.Avg_Demand_Used * 3) - COALESCE(soh.On_Hand_Qty,0), 0)
      ELSE NULL
    END AS Stock_Shortfall,
    CASE
      WHEN dbs.Avg_Demand_Used > 0 THEN GREATEST(3 - (COALESCE(soh.On_Hand_Qty,0) / dbs.Avg_Demand_Used), 0)
      ELSE NULL
    END AS Months_Short
  FROM sales_by_sku sb
  LEFT JOIN demand_by_sku dbs ON sb.SKU = dbs.SKU
  LEFT JOIN soh_by_sku soh    ON sb.SKU = soh.SKU
  LEFT JOIN last_price_by_sku lp ON sb.SKU = lp.SKU
  LEFT JOIN items_fallback_by_sku itfb ON sb.SKU = itfb.SKU
)
SELECT *
FROM enriched
WHERE SKU IS NOT NULL AND TRIM(SKU) <> ''
  AND SKU NOT LIKE '800-%'
  AND SKU NOT LIKE '2000-%'
ORDER BY SKU;
```

## 5. Adding Cost Delta (optional)
If you add a `Current_Unit_Rate` column (e.g. from a normalized cost QT) join it into `enriched` and append:
```sql
  (lp.Last_Purchase_Price - cur.Current_Unit_Rate) AS Cost_Delta,
  CASE WHEN cur.Current_Unit_Rate > 0 THEN (lp.Last_Purchase_Price - cur.Current_Unit_Rate)/cur.Current_Unit_Rate ELSE NULL END AS Cost_Delta_Pct
```

## 6. Troubleshooting Cheatsheet
| Symptom | Likely Cause | Fix |
|---------|--------------|-----|
| Invalid column Product_ID | Column actually named "Product ID" or alias lost | Double-click column; re-alias AS Product_ID in CTE |
| Invalid column SKU_final | Not aliased in bridge CTE | Ensure `AS SKU` or `AS SKU_final` and reference consistently |
| All joins NULL | Bridge missing rows | Inspect `sku_bridge` for blanks; enforce SKU not null filter earlier |
| Zero rows after WHERE | Prefix exclusions remove all | Temporarily drop prefix filters; count excluded SKUs |

## 7. Row Count Diagnostics
Quick counts before filters:
```sql
WITH b AS (
  SELECT DISTINCT SKU FROM sku_bridge WHERE SKU IS NOT NULL AND TRIM(SKU) <> ''
)
SELECT COUNT(*) AS DistinctSKU FROM b;
```
Count excluded prefixes:
```sql
SELECT
  SUM(CASE WHEN SKU LIKE '800-%' THEN 1 ELSE 0 END) AS Excl800,
  SUM(CASE WHEN SKU LIKE '2000-%' THEN 1 ELSE 0 END) AS Excl2000
FROM enriched;
```

## 8. Save Sequence
1. Run steps 1–3 probes (LIMIT).
2. Run full aggregation (step 4) without prefix WHERE to confirm counts.
3. Add strict WHERE exclusions.
4. Save As (flatten headers).

## 9. Next Enhancements
- Currency conversion (CRC→USD) using Exchange Rate table.
- Safety stock horizon parameterized (replace literal 3 with variable via another QT or manual edit).
- Add rolling 6M sales velocity (SUM last 6 months by SKU).

---
Copy sections as needed; keep them unmodified for consistent behavior.
