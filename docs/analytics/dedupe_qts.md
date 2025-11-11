# Zoho Analytics — Dedupe and Union Query Tables (Exact Scripts)

Use these scripts to ensure one row per Product_ID + Month_Year and to safely union future months from clean sales. Names match your current setup.

## Tables assumed
- Base: `item_snapshot_base` (imported from `qt_item_snapshot_sales_enriched_v6_merged.csv`)
- Clean sales lines (the file you import over time): `clean_sales_lines`
- Calendar: `calendar_months`

If your clean file is already monthly (one row per Product_ID+Month_Year), you can still import it into `clean_sales_lines`; the monthly rollup view will simply pass values through.

---

## 0) Audit duplicates (optional)
```sql
SELECT
  concat(trim(Product_ID), '-', trim(Month_Year)) AS row_key,
  COUNT(*) AS dup_count
FROM item_snapshot_base
GROUP BY concat(trim(Product_ID), '-', trim(Month_Year))
HAVING COUNT(*) > 1
ORDER BY dup_count DESC;
```

## 1) Monthly rollup of clean sales lines
Collapse any multiple rows per Product_ID+Month_Year in your clean imports.

Create view: `clean_sales_monthly`
```sql
SELECT
  Product_ID,
  Month_Year,
  SUM(Total_Quantity) AS Total_Quantity,
  SUM(Net_Sales)      AS Net_Sales,
  MAX(Item_ID)        AS Item_ID
FROM clean_sales_lines
GROUP BY Product_ID, Month_Year;
```

## 2) De-duplicated base
Guarantees one row per Product_ID+Month_Year from the base import.

Create view: `item_snapshot_base_dedup`
```sql
SELECT
  Product_ID,
  Month_Year,
  MAX(SKU)                         AS SKU,
  SUM(Total_Quantity)              AS Total_Quantity,
  SUM(Net_Sales)                   AS Net_Sales,
  MAX(Available_Stock)             AS Available_Stock,
  MAX(Cost_Fallback_Text)          AS Cost_Fallback_Text,
  MAX(Cost_Fallback_Num)           AS Cost_Fallback_Num,
  MAX(Last_Purchase_Price)         AS Last_Purchase_Price,
  MAX(Stock_On_Hand)               AS Stock_On_Hand,
  MAX(Avg_Demand_6M)               AS Avg_Demand_6M,
  MAX(Reorder_Flag)                AS Reorder_Flag,
  MAX(Unit_Cost_CRC)               AS Unit_Cost_CRC,
  MAX(On_Hand_Qty)                 AS On_Hand_Qty,
  MAX(Inventory_Value_CRC)         AS Inventory_Value_CRC,
  MAX(Months_Cover)                AS Months_Cover,
  MAX(Reorder_Qty_Lead2m)          AS Reorder_Qty_Lead2m,
  MAX(Item_ID)                     AS Item_ID
FROM item_snapshot_base
GROUP BY Product_ID, Month_Year;
```

## 3) Union with overrides + new months
Use the deduped base and the monthly rolled-up clean sales. This provides overrides on overlapping months and adds brand new months.

Create view: `sales_union`
```sql
-- Overwrite existing months with cleaned metrics when present
SELECT
  b.Product_ID,
  b.Month_Year,
  COALESCE(c.Total_Quantity, b.Total_Quantity) AS Total_Quantity,
  COALESCE(c.Net_Sales,     b.Net_Sales)       AS Net_Sales,
  COALESCE(c.Item_ID,       b.Item_ID)         AS Item_ID
FROM item_snapshot_base_dedup b
LEFT JOIN clean_sales_monthly c
  ON c.Product_ID = b.Product_ID
 AND c.Month_Year = b.Month_Year

UNION ALL

-- Add new months not in base
SELECT
  c.Product_ID,
  c.Month_Year,
  c.Total_Quantity,
  c.Net_Sales,
  c.Item_ID
FROM clean_sales_monthly c
LEFT JOIN item_snapshot_base_dedup b
  ON b.Product_ID = c.Product_ID
 AND b.Month_Year = c.Month_Year
WHERE b.Product_ID IS NULL;
```

## 4) Reporting view with year-safe 6M average
Joins the unioned sales to attributes and calendar; computes Avg_Demand_6M.

Create view: `item_snapshot_reporting`
```sql
WITH item_dims AS (
  SELECT
    Product_ID,
    MAX(SKU)                    AS SKU,
    MAX(Available_Stock)        AS Available_Stock,
    MAX(Cost_Fallback_Text)     AS Cost_Fallback_Text,
    MAX(Cost_Fallback_Num)      AS Cost_Fallback_Num,
    MAX(Last_Purchase_Price)    AS Last_Purchase_Price,
    MAX(Unit_Cost_CRC)          AS Unit_Cost_CRC,
    MAX(On_Hand_Qty)            AS On_Hand_Qty,
    MAX(Inventory_Value_CRC)    AS Inventory_Value_CRC
  FROM item_snapshot_base_dedup
  GROUP BY Product_ID
)
SELECT
  s.Product_ID,
  d.SKU,
  s.Month_Year,
  s.Total_Quantity,
  s.Net_Sales,
  d.Available_Stock,
  d.Cost_Fallback_Text,
  d.Cost_Fallback_Num,
  d.Last_Purchase_Price,
  d.Unit_Cost_CRC,
  d.On_Hand_Qty,
  d.Inventory_Value_CRC,
  s.Item_ID,
  cal.YYYY,
  cal.MM,
  cal.YYYYMM,
  (
    SELECT SUM(s2.Total_Quantity) / 6.0
    FROM sales_union s2
    JOIN calendar_months cal2 ON cal2.Month_Year = s2.Month_Year
    WHERE s2.Product_ID = s.Product_ID
      AND cal2.YYYYMM BETWEEN cal.Start6_YYYYMM AND cal.YYYYMM
  ) AS Avg_Demand_6M
FROM sales_union s
LEFT JOIN item_dims d
  ON d.Product_ID = s.Product_ID
LEFT JOIN calendar_months cal
  ON cal.Month_Year = s.Month_Year;
```

> If your Zoho Analytics parser disallows WITH, create `item_dims` as a separate view and reference it in the final SELECT.

## 5) Primary key enforcement
- In `item_snapshot_base` (or after you replace it with the deduped export), create a formula column `row_key = concat(trim(Product_ID), '-', trim(Month_Year))` and mark it as Primary Key.
- In `clean_sales_lines`, you can rely on the import wizard’s multi-column match (Product_ID, Month_Year) or add the same `row_key` formula and select that as the PK.

## 6) Import guidance
- For `clean_sales_lines`: choose “Update matching rows and add new ones”; match on (Product_ID, Month_Year).
- Schedule monthly imports so future months appear automatically in `sales_union` and `item_snapshot_reporting`.

## Notes
- All IDs should be Text; Month_Year as Text YYYY-MM.
- The monthly rollup prevents row multiplication when clean files contain multiple invoice lines per month.
- The union pattern keeps your base lightweight while clean_sales can grow independently.
