# Zoho Analytics — Item Snapshot Base and Rolling View

This guide sets up a maintainable base in Zoho Analytics so new sales history is automatically included by importing your clean sales file.

## Tables you will import

1) item_snapshot_base (from repo)
- Source file: data/qt_item_snapshot_sales_enriched_v6_merged.csv
- Keys: composite primary key (Product_ID, Month_Year)
- Recommended data types:
  - Product_ID: Text
  - SKU: Text
  - Month_Year: Text (format YYYY-MM)
  - Total_Quantity, Net_Sales: Number (Double)
  - Available_Stock: Number (Integer)
  - Cost_Fallback_Text: Text
  - Cost_Fallback_Num: Number (Double)
  - Last_Purchase_Price: Number (Double)
  - Stock_On_Hand: Number (Double)
  - Avg_Demand_6M: Number (Double)
  - Reorder_Flag: Number (Integer)
  - Unit_Cost_CRC: Number (Double)
  - On_Hand_Qty: Number (Double)
  - Inventory_Value_CRC: Number (Double)
  - Months_Cover: Number (Double)
  - Reorder_Qty_Lead2m: Number (Integer)
  - Item_ID: Text (if present)

2) clean_sales (to refresh over time)
- Source file example: data/qt_sales_24m_clean(2).csv (or any future monthly/rolling export)
- Keys: composite (Product_ID, Month_Year)
- Columns expected (minimum):
  - Product_ID (Text)
  - Month_Year (Text, YYYY-MM)
  - Total_Quantity (Double)
  - Net_Sales (Double)
  - Item_ID (Text) optional
- Import setting: Add records and update existing records by matching keys (Product_ID, Month_Year).
- Schedule: Set an import schedule (e.g., monthly) to automatically pull new months.

3) calendar_months (from repo)
- Source file: data/calendar_months.csv
- Columns:
  - Month_Year (Text YYYY-MM)
  - YYYY (Integer), MM (Integer)
  - YYYYMM (Integer)
  - Start6_YYYYMM (Integer) — start of the 6M window inclusive

## Query Tables to create

Create these as Query Tables (Views) in the listed order.

A) item_dims (simple attributes by Product_ID)

```sql
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
FROM item_snapshot_base
GROUP BY Product_ID;
```

Notes:
- Using MAX as a convenient aggregator to get a representative attribute per Product_ID; adjust if you prefer more rigorous "latest" logic.

B) sales_union (base plus clean sales; includes new months not in base)

```sql
-- 1) Base rows with cleaned overrides where available
SELECT
  b.Product_ID,
  b.Month_Year,
  COALESCE(c.Total_Quantity, b.Total_Quantity) AS Total_Quantity,
  COALESCE(c.Net_Sales,     b.Net_Sales)       AS Net_Sales,
  COALESCE(c.Item_ID,       b.Item_ID)         AS Item_ID
FROM item_snapshot_base b
LEFT JOIN clean_sales c
  ON c.Product_ID = b.Product_ID
 AND c.Month_Year = b.Month_Year

UNION ALL

-- 2) New rows that exist only in clean_sales (future months)
SELECT
  c.Product_ID,
  c.Month_Year,
  c.Total_Quantity,
  c.Net_Sales,
  c.Item_ID
FROM clean_sales c
LEFT JOIN item_snapshot_base b
  ON b.Product_ID = c.Product_ID
 AND b.Month_Year = c.Month_Year
WHERE b.Product_ID IS NULL;
```

C) item_snapshot_reporting (joins sales to dims and calendar, adds 6M average)

```sql
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
  /* Year-safe 6M average using calendar window */
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

Optional: add reorder metrics in a follow-up Query Table that references `item_snapshot_reporting` (to avoid deep nesting).

## Recommended keys and formats
- Treat IDs as Text to preserve long numeric strings.
- Keep Month_Year as Text (YYYY-MM). The calendar table provides YYYYMM for window math.
- Define a composite primary key on (Product_ID, Month_Year) for `item_snapshot_base` and `clean_sales` to enable safe upserts.

## Ongoing maintenance
- Upload new clean sales files into `clean_sales` on a schedule (Add/Update by keys).
- If base attributes change (e.g., new SKU or cost), you can periodically refresh `item_snapshot_base` by re-importing a regenerated v6 file. The views will adapt automatically.
- All rolling logic is in views; no need to recompute offline when sales grow.
