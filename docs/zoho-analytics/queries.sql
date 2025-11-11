/* =============================================================
   Zoho Analytics Enrichment SQL Bundle
   Copy individual blocks into Zoho Query Table editor.
   ============================================================= */

/* -------------------------------------------------------------
   1. Last Purchase Base (qt_last_purchase_base)
   ------------------------------------------------------------- */
SELECT
  poi."Item ID"            AS Item_ID,
  poi."Product ID"         AS Product_ID,
  TRIM(poi."Item Name")    AS Item_Name,
  po."Purchase Order Date" AS Purchase_Order_Date,
  po."Purchase Order Status" AS Purchase_Order_Status,
  poi."Quantity"           AS Quantity,
  /* Unit price = cleaned Sub Total / Quantity */
  (CAST(REPLACE(REPLACE(REPLACE(poi."Sub Total (BCY)", 'CRC ', ''), ',', ''), ' ', '') AS DOUBLE) /
    NULLIF(CAST(poi."Quantity" AS DOUBLE), 0)) AS Unit_Price_BCY
FROM "Purchase Order Items" poi
LEFT JOIN "Purchase Orders" po
  ON poi."Purchase Order ID" = po."Purchase Order ID"
WHERE po."Purchase Order Date" IS NOT NULL
  AND po."Purchase Order Status" NOT IN ('Cancelled')
  AND CAST(poi."Quantity" AS DOUBLE) > 0
  AND poi."Sub Total (BCY)" IS NOT NULL;

/* -------------------------------------------------------------
   2. Most Recent Purchase Per Item (qt_last_purchase)
   Note: Ensure qt_last_purchase_base is SAVED as a Query Table first.
         Rewritten to avoid correlated subquery alias issues in Zoho.
         If ROW_NUMBER is supported, a window function version can replace this.
     Dependency Warning: If Zoho blocks edits citing columns used downstream
     (e.g., 'SKU', 'Product_ID', 'Last_Purchase_Date'), DO NOT edit the
     existing qt_last_purchase table directly. Instead:
    a) Save this SQL as a NEW table name (e.g., qt_last_purchase_v2).
    b) Update downstream Query Tables to reference qt_last_purchase_v2.
    c) Once all dependencies are switched, delete or archive the old one.
   ------------------------------------------------------------- */
SELECT
  SELECT
    d.Item_ID                         AS Item_ID,
    d.SKU                             AS SKU,
    d.Sales_24M_Qty                   AS Sales_24M_Qty,
    d.Sales_24M_Net                   AS Sales_24M_Net,
    CAST(d.Avg_Demand_Used AS DOUBLE) AS Avg_Demand_Used,
    /* lp date/price names come from qt_last_purchase_v2 preview
       Use the exact identifier shown in the picker */
    lp."m.Last_Purchase_Date"         AS Last_Purchase_Date,
    lp.Last_Purchase_Price            AS Last_Purchase_Price,
    fp.Purchase_Price_Fallback        AS Last_Purchase_Price_Fallback,
    CAST(st."s.On_Hand_Qty" AS DOUBLE)    AS On_Hand_Qty,
    CAST(st.Current_Unit_Rate AS DOUBLE)   AS Current_Unit_Rate,
    CASE
      WHEN st."s.On_Hand_Qty" IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND CAST(d.Avg_Demand_Used AS DOUBLE) > 0
        THEN CAST(st."s.On_Hand_Qty" AS DOUBLE) / CAST(d.Avg_Demand_Used AS DOUBLE)
      ELSE NULL END AS Coverage_Months,
    CASE
      WHEN d.Avg_Demand_Used IS NOT NULL AND st."s.On_Hand_Qty" IS NOT NULL THEN
        CASE WHEN (CAST(d.Avg_Demand_Used AS DOUBLE) * 3) - CAST(st."s.On_Hand_Qty" AS DOUBLE) > 0
             THEN (CAST(d.Avg_Demand_Used AS DOUBLE) * 3) - CAST(st."s.On_Hand_Qty" AS DOUBLE)
             ELSE 0 END
      ELSE NULL END AS Stock_Shortfall,
    CASE
      WHEN ((st."s.On_Hand_Qty" IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND (CAST(d.Avg_Demand_Used AS DOUBLE) * 3) - CAST(st."s.On_Hand_Qty" AS DOUBLE) > 0)
         OR (st."s.On_Hand_Qty" IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND CAST(st."s.On_Hand_Qty" AS DOUBLE) / CAST(d.Avg_Demand_Used AS DOUBLE) <= 1))
        THEN 1 ELSE 0 END AS Reorder_Eligibility,
    CASE
      WHEN lp.Last_Purchase_Price IS NOT NULL AND fp.Purchase_Price_Fallback IS NOT NULL AND fp.Purchase_Price_Fallback > 0
        THEN lp.Last_Purchase_Price - fp.Purchase_Price_Fallback
      ELSE NULL END AS Cost_Delta,
    CASE
      WHEN lp.Last_Purchase_Price IS NOT NULL AND fp.Purchase_Price_Fallback IS NOT NULL AND fp.Purchase_Price_Fallback > 0
        THEN (lp.Last_Purchase_Price - fp.Purchase_Price_Fallback) / fp.Purchase_Price_Fallback * 100.0
      ELSE NULL END AS Cost_Delta_Pct

/* -------------------------------------------------------------
   3. Last Purchase Fallback (qt_last_purchase_fallback)
   ------------------------------------------------------------- */
SELECT
  it."Item ID" AS Item_ID,
  it."SKU"     AS SKU,
  CAST(REPLACE(REPLACE(REPLACE(it."Purchase Price", 'CRC ', ''), ',', ''), ' ', '') AS DOUBLE) AS Purchase_Price_Fallback
FROM Items it
WHERE it."Purchase Price" IS NOT NULL
  AND TRIM(it."Purchase Price") <> '';

/* -------------------------------------------------------------
   3b. Last Purchase Fallback v2 (qt_last_purchase_fallback_v2)
   Use this to bypass dependency locks. Create as a NEW table.
   ------------------------------------------------------------- */
SELECT
  it."Item ID" AS Item_ID,
  it."SKU"     AS SKU,
  CAST(REPLACE(REPLACE(REPLACE(it."Purchase Price", 'CRC ', ''), ',', ''), ' ', '') AS DOUBLE) AS Purchase_Price_Fallback
FROM Items it
WHERE it."Purchase Price" IS NOT NULL
  AND TRIM(it."Purchase Price") <> '';

/* -------------------------------------------------------------
   4. Stock On Hand Raw (qt_stock_on_hand)
   FULL OUTER JOIN emulated via UNION since Zoho may not support FULL OUTER
   ------------------------------------------------------------- */
/* Part A: rows from item_stock_on_hand */
SELECT
  soh.Item_ID AS Item_ID,
  TRIM(soh."inv.SKU") AS SKU,
  CAST(soh.On_Hand_Qty AS DOUBLE) AS On_Hand_Qty,
  NULL AS Current_Unit_Rate_Raw
FROM item_stock_on_hand soh

UNION ALL
/* Part B: rows from Inventory export not present in stock file */
SELECT
  inv."Item ID" AS Item_ID,
  TRIM(inv."SKU") AS SKU,
  CASE WHEN inv."Stock On Hand" IS NOT NULL AND TRIM(inv."Stock On Hand") <> ''
       THEN CAST(inv."Stock On Hand" AS DOUBLE) ELSE NULL END AS On_Hand_Qty,
  CAST(REPLACE(REPLACE(REPLACE(inv."Purchase Price", 'CRC ', ''), ',', ''), ' ', '') AS DOUBLE) AS Current_Unit_Rate_Raw
FROM "Inventory_Items_Export_2025-11-08" inv
LEFT JOIN item_stock_on_hand s
  ON s.Item_ID = inv."Item ID"
WHERE s.Item_ID IS NULL;

/* -------------------------------------------------------------
   5. Stock On Hand Final (qt_stock_on_hand_final)
   ------------------------------------------------------------- */
SELECT
  s.Item_ID,
  s.SKU,
  s.On_Hand_Qty,
  CASE
    WHEN s.Current_Unit_Rate_Raw IS NOT NULL AND s.Current_Unit_Rate_Raw > 0 THEN s.Current_Unit_Rate_Raw
    ELSE fp.Purchase_Price_Fallback
  END AS Current_Unit_Rate
FROM qt_stock_on_hand s
LEFT JOIN qt_last_purchase_fallback fp
  ON s.Item_ID = fp.Item_ID AND (fp.SKU = s.SKU OR fp.SKU IS NULL);

/* -------------------------------------------------------------
   5b. Stock On Hand Final v2 (qt_stock_on_hand_final_v2)
   Same logic but joins to qt_last_purchase_fallback_v2 to avoid locks.
   ------------------------------------------------------------- */
SELECT
  s.Item_ID,
  s.SKU,
  s.On_Hand_Qty,
  CASE
    WHEN s.Current_Unit_Rate_Raw IS NOT NULL AND s.Current_Unit_Rate_Raw > 0 THEN s.Current_Unit_Rate_Raw
    ELSE fp.Purchase_Price_Fallback
  END AS Current_Unit_Rate
FROM qt_stock_on_hand s
LEFT JOIN qt_last_purchase_fallback_v2 fp
  ON s.Item_ID = fp.Item_ID AND (fp.SKU = s.SKU OR fp.SKU IS NULL);

/* -------------------------------------------------------------
   6. Demand Base 24m (qt_demand_base_24m) — optional if not already present
   ------------------------------------------------------------- */
SELECT
  sb.Item_ID,
  TRIM(sb.SKU) AS SKU,
  sb.Sales_24M_Qty,
  sb.Sales_24M_Net,
  CASE WHEN sb.Sales_24M_Qty IS NOT NULL THEN CAST(sb.Sales_24M_Qty AS DOUBLE)/24 ELSE NULL END AS Avg_Demand_Used
FROM item_sales_24m_base sb;

/* -------------------------------------------------------------
   6b. Demand Base 24m v2 (qt_demand_base_24m_v2)
   Flatten dotted headers from qt_demand_base_24m to clean aliases.
   Use this if your qt_demand_base_24m shows columns like "sb.Item_ID".
   ------------------------------------------------------------- */
SELECT
  db."sb.Item_ID"       AS Item_ID,
  db.SKU                 AS SKU,
  db."sb.Sales_24M_Qty" AS Sales_24M_Qty,
  db."sb.Sales_24M_Net" AS Sales_24M_Net,
  db.Avg_Demand_Used     AS Avg_Demand_Used
FROM qt_demand_base_24m db;

/* -------------------------------------------------------------
   7. Unified Enrichment Snapshot (qt_item_snapshot_enriched_vX)
   Replace GREATEST with CASE if unsupported.
   ------------------------------------------------------------- */
SELECT
  d.Item_ID,
  d.SKU,
  d.Sales_24M_Qty,
  d.Sales_24M_Net,
  d.Avg_Demand_Used,
  lp.Last_Purchase_Date,
  lp.Last_Purchase_Price,
  fp.Purchase_Price_Fallback AS Last_Purchase_Price_Fallback,
  st.On_Hand_Qty,
  st.Current_Unit_Rate,
  CASE
    WHEN st.On_Hand_Qty IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND CAST(d.Avg_Demand_Used AS DOUBLE) > 0
      THEN st.On_Hand_Qty / d.Avg_Demand_Used
    ELSE NULL END AS Coverage_Months,
  CASE
    WHEN d.Avg_Demand_Used IS NOT NULL AND st.On_Hand_Qty IS NOT NULL THEN
      CASE WHEN (d.Avg_Demand_Used * 3) - st.On_Hand_Qty > 0 THEN (d.Avg_Demand_Used * 3) - st.On_Hand_Qty ELSE 0 END
    ELSE NULL END AS Stock_Shortfall,
  CASE
    WHEN ((st.On_Hand_Qty IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND (d.Avg_Demand_Used * 3) - st.On_Hand_Qty > 0)
       OR (st.On_Hand_Qty IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND st.On_Hand_Qty / d.Avg_Demand_Used <= 1))
      THEN 1 ELSE 0 END AS Reorder_Eligibility,
  CASE
    WHEN lp.Last_Purchase_Price IS NOT NULL AND fp.Purchase_Price_Fallback IS NOT NULL AND fp.Purchase_Price_Fallback > 0
      THEN lp.Last_Purchase_Price - fp.Purchase_Price_Fallback
    ELSE NULL END AS Cost_Delta,
  CASE
    WHEN lp.Last_Purchase_Price IS NOT NULL AND fp.Purchase_Price_Fallback IS NOT NULL AND fp.Purchase_Price_Fallback > 0
      THEN (lp.Last_Purchase_Price - fp.Purchase_Price_Fallback) / fp.Purchase_Price_Fallback * 100.0
    ELSE NULL END AS Cost_Delta_Pct
FROM qt_demand_base_24m d
LEFT JOIN qt_last_purchase lp ON d.Item_ID = lp.Item_ID
LEFT JOIN qt_last_purchase_fallback fp ON d.Item_ID = fp.Item_ID
LEFT JOIN qt_stock_on_hand_final st ON d.Item_ID = st.Item_ID
WHERE NOT ((d.SKU IS NULL OR TRIM(d.SKU) = '') AND st.On_Hand_Qty IS NOT NULL AND st.On_Hand_Qty > 0);

/* -------------------------------------------------------------
   7c. Unified Enrichment Snapshot (qt_item_snapshot_enriched_v2_alt)
   Use this variant IF you have NOT yet created qt_demand_base_24m_v2.
   It reads directly from qt_demand_base_24m quoting the dotted columns.
   Steps:
     1. Skip creating the flatten table if you wish; use this block instead.
     2. Save As e.g. qt_item_snapshot_enriched_v2_alt (or materialized flat tbl).
   ------------------------------------------------------------- */
SELECT
  d."sb.Item_ID"         AS Item_ID,
  d.SKU,
  d."sb.Sales_24M_Qty"   AS Sales_24M_Qty,
  d."sb.Sales_24M_Net"   AS Sales_24M_Net,
  d.Avg_Demand_Used,
  lp.Last_Purchase_Date,
  lp.Last_Purchase_Price,
  fp.Purchase_Price_Fallback AS Last_Purchase_Price_Fallback,
  st.On_Hand_Qty,
  st.Current_Unit_Rate,
  CASE
    WHEN st.On_Hand_Qty IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND CAST(d.Avg_Demand_Used AS DOUBLE) > 0
      THEN st.On_Hand_Qty / d.Avg_Demand_Used
    ELSE NULL END AS Coverage_Months,
  CASE
    WHEN d.Avg_Demand_Used IS NOT NULL AND st.On_Hand_Qty IS NOT NULL THEN
      CASE WHEN (d.Avg_Demand_Used * 3) - st.On_Hand_Qty > 0 THEN (d.Avg_Demand_Used * 3) - st.On_Hand_Qty ELSE 0 END
    ELSE NULL END AS Stock_Shortfall,
  CASE
    WHEN ((st.On_Hand_Qty IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND (d.Avg_Demand_Used * 3) - st.On_Hand_Qty > 0)
       OR (st.On_Hand_Qty IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND st.On_Hand_Qty / d.Avg_Demand_Used <= 1))
      THEN 1 ELSE 0 END AS Reorder_Eligibility,
  CASE
    WHEN lp.Last_Purchase_Price IS NOT NULL AND fp.Purchase_Price_Fallback IS NOT NULL AND fp.Purchase_Price_Fallback > 0
      THEN lp.Last_Purchase_Price - fp.Purchase_Price_Fallback
    ELSE NULL END AS Cost_Delta,
  CASE
    WHEN lp.Last_Purchase_Price IS NOT NULL AND fp.Purchase_Price_Fallback IS NOT NULL AND fp.Purchase_Price_Fallback > 0
      THEN (lp.Last_Purchase_Price - fp.Purchase_Price_Fallback) / fp.Purchase_Price_Fallback * 100.0
    ELSE NULL END AS Cost_Delta_Pct
FROM qt_demand_base_24m d
LEFT JOIN qt_last_purchase_v2 lp ON d."sb.Item_ID" = lp.Item_ID
LEFT JOIN qt_last_purchase_fallback_v2 fp ON d."sb.Item_ID" = fp.Item_ID
LEFT JOIN qt_stock_on_hand_final_v4 st ON d."sb.Item_ID" = st.Item_ID
WHERE NOT ((d.SKU IS NULL OR TRIM(d.SKU) = '') AND st.On_Hand_Qty IS NOT NULL AND st.On_Hand_Qty > 0);

/* -------------------------------------------------------------
   7c_fix. Unified Enrichment Snapshot (qt_item_snapshot_enriched_v2_alt_fix)
   Use this variant IF saving 7c shows "Invalid column 'Item_ID' used in SELECT".
   Some Zoho engines cannot qualify dotted column names with a table alias
   (i.e., d."sb.Item_ID"). In that case, do NOT alias the base table and
   reference dotted columns directly with double quotes.
   Steps:
     1) Paste this into a NEW Query Table and Save As e.g.
        qt_item_snapshot_enriched_v2_alt_fix (or your preferred name).
     2) Point KPIs to the materialized name you save.
   ------------------------------------------------------------- */
SELECT
  "sb.Item_ID"         AS Item_ID,
  SKU,
  "sb.Sales_24M_Qty"   AS Sales_24M_Qty,
  "sb.Sales_24M_Net"   AS Sales_24M_Net,
  Avg_Demand_Used,
  lp.Last_Purchase_Date,
  lp.Last_Purchase_Price,
  fp.Purchase_Price_Fallback AS Last_Purchase_Price_Fallback,
  st.On_Hand_Qty,
  st.Current_Unit_Rate,
  CASE
    WHEN st.On_Hand_Qty IS NOT NULL AND Avg_Demand_Used IS NOT NULL AND CAST(Avg_Demand_Used AS DOUBLE) > 0
      THEN st.On_Hand_Qty / Avg_Demand_Used
    ELSE NULL END AS Coverage_Months,
  CASE
    WHEN Avg_Demand_Used IS NOT NULL AND st.On_Hand_Qty IS NOT NULL THEN
      CASE WHEN (Avg_Demand_Used * 3) - st.On_Hand_Qty > 0 THEN (Avg_Demand_Used * 3) - st.On_Hand_Qty ELSE 0 END
    ELSE NULL END AS Stock_Shortfall,
  CASE
    WHEN ((st.On_Hand_Qty IS NOT NULL AND Avg_Demand_Used IS NOT NULL AND (Avg_Demand_Used * 3) - st.On_Hand_Qty > 0)
       OR (st.On_Hand_Qty IS NOT NULL AND Avg_Demand_Used IS NOT NULL AND st.On_Hand_Qty / Avg_Demand_Used <= 1))
      THEN 1 ELSE 0 END AS Reorder_Eligibility,
  CASE
    WHEN lp.Last_Purchase_Price IS NOT NULL AND fp.Purchase_Price_Fallback IS NOT NULL AND fp.Purchase_Price_Fallback > 0
      THEN lp.Last_Purchase_Price - fp.Purchase_Price_Fallback
    ELSE NULL END AS Cost_Delta,
  CASE
    WHEN lp.Last_Purchase_Price IS NOT NULL AND fp.Purchase_Price_Fallback IS NOT NULL AND fp.Purchase_Price_Fallback > 0
      THEN (lp.Last_Purchase_Price - fp.Purchase_Price_Fallback) / fp.Purchase_Price_Fallback * 100.0
    ELSE NULL END AS Cost_Delta_Pct
FROM qt_demand_base_24m
LEFT JOIN qt_last_purchase_v2 lp ON "sb.Item_ID" = lp.Item_ID
LEFT JOIN qt_last_purchase_fallback_v2 fp ON "sb.Item_ID" = fp.Item_ID
LEFT JOIN qt_stock_on_hand_final_v4 st ON "sb.Item_ID" = st.Item_ID
WHERE NOT ((SKU IS NULL OR TRIM(SKU) = '') AND st.On_Hand_Qty IS NOT NULL AND st.On_Hand_Qty > 0);

/* -------------------------------------------------------------
   7c_fix2. Unified Enrichment Snapshot (qt_item_snapshot_enriched_v2_alt_fix2)
   If 7c_fix still errors on 'Item_ID', use a derived subselect to decouple
   the alias name from joins and fully-qualify non-dotted base columns.
   This keeps the final output column named Item_ID while avoiding engine
   validation quirks.
   ------------------------------------------------------------- */
SELECT
  d.Base_Item_ID        AS Item_ID,
  d.SKU,
  d.Sales_24M_Qty,
  d.Sales_24M_Net,
  d.Avg_Demand_Used,
  lp.Last_Purchase_Date,
  lp.Last_Purchase_Price,
  fp.Purchase_Price_Fallback AS Last_Purchase_Price_Fallback,
  st.On_Hand_Qty,
  st.Current_Unit_Rate,
  CASE
    WHEN st.On_Hand_Qty IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND CAST(d.Avg_Demand_Used AS DOUBLE) > 0
      THEN st.On_Hand_Qty / d.Avg_Demand_Used
    ELSE NULL END AS Coverage_Months,
  CASE
    WHEN d.Avg_Demand_Used IS NOT NULL AND st.On_Hand_Qty IS NOT NULL THEN
      CASE WHEN (d.Avg_Demand_Used * 3) - st.On_Hand_Qty > 0 THEN (d.Avg_Demand_Used * 3) - st.On_Hand_Qty ELSE 0 END
    ELSE NULL END AS Stock_Shortfall,
  CASE
    WHEN ((st.On_Hand_Qty IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND (d.Avg_Demand_Used * 3) - st.On_Hand_Qty > 0)
       OR (st.On_Hand_Qty IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND st.On_Hand_Qty / d.Avg_Demand_Used <= 1))
      THEN 1 ELSE 0 END AS Reorder_Eligibility,
  CASE
    WHEN lp.Last_Purchase_Price IS NOT NULL AND fp.Purchase_Price_Fallback IS NOT NULL AND fp.Purchase_Price_Fallback > 0
      THEN lp.Last_Purchase_Price - fp.Purchase_Price_Fallback
    ELSE NULL END AS Cost_Delta,
  CASE
    WHEN lp.Last_Purchase_Price IS NOT NULL AND fp.Purchase_Price_Fallback IS NOT NULL AND fp.Purchase_Price_Fallback > 0
      THEN (lp.Last_Purchase_Price - fp.Purchase_Price_Fallback) / fp.Purchase_Price_Fallback * 100.0
    ELSE NULL END AS Cost_Delta_Pct
FROM (
  SELECT
    "sb.Item_ID"       AS Base_Item_ID,
    qt_demand_base_24m.SKU AS SKU,
    "sb.Sales_24M_Qty" AS Sales_24M_Qty,
    "sb.Sales_24M_Net" AS Sales_24M_Net,
    qt_demand_base_24m.Avg_Demand_Used AS Avg_Demand_Used
  FROM qt_demand_base_24m
 ) d
LEFT JOIN qt_last_purchase_v2 lp ON d.Base_Item_ID = lp.Item_ID
LEFT JOIN qt_last_purchase_fallback_v2 fp ON d.Base_Item_ID = fp.Item_ID
LEFT JOIN qt_stock_on_hand_final_v4 st ON d.Base_Item_ID = st.Item_ID
WHERE NOT ((d.SKU IS NULL OR TRIM(d.SKU) = '') AND st.On_Hand_Qty IS NOT NULL AND st.On_Hand_Qty > 0);

/* -------------------------------------------------------------
   7b. Unified Enrichment Snapshot v2 (qt_item_snapshot_enriched_v2)
   References qt_last_purchase_v2 and qt_stock_on_hand_final_v2.
   Save As a table (e.g., item_snapshot_enriched_flat_tbl_v2) to materialize.
   ------------------------------------------------------------- */
SELECT
  d.Item_ID,
  d.SKU,
  d.Sales_24M_Qty,
  d.Sales_24M_Net,
  d.Avg_Demand_Used,
  lp.Last_Purchase_Date,
  lp.Last_Purchase_Price,
  fp.Purchase_Price_Fallback AS Last_Purchase_Price_Fallback,
  st.On_Hand_Qty,
  st.Current_Unit_Rate,
  CASE
    WHEN st.On_Hand_Qty IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND CAST(d.Avg_Demand_Used AS DOUBLE) > 0
      THEN st.On_Hand_Qty / d.Avg_Demand_Used
    ELSE NULL END AS Coverage_Months,
  CASE
    WHEN d.Avg_Demand_Used IS NOT NULL AND st.On_Hand_Qty IS NOT NULL THEN
      CASE WHEN (d.Avg_Demand_Used * 3) - st.On_Hand_Qty > 0 THEN (d.Avg_Demand_Used * 3) - st.On_Hand_Qty ELSE 0 END
    ELSE NULL END AS Stock_Shortfall,
  CASE
    WHEN ((st.On_Hand_Qty IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND (d.Avg_Demand_Used * 3) - st.On_Hand_Qty > 0)
       OR (st.On_Hand_Qty IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND st.On_Hand_Qty / d.Avg_Demand_Used <= 1))
      THEN 1 ELSE 0 END AS Reorder_Eligibility,
  CASE
    WHEN lp.Last_Purchase_Price IS NOT NULL AND fp.Purchase_Price_Fallback IS NOT NULL AND fp.Purchase_Price_Fallback > 0
      THEN lp.Last_Purchase_Price - fp.Purchase_Price_Fallback
    ELSE NULL END AS Cost_Delta,
  CASE
    WHEN lp.Last_Purchase_Price IS NOT NULL AND fp.Purchase_Price_Fallback IS NOT NULL AND fp.Purchase_Price_Fallback > 0
      THEN (lp.Last_Purchase_Price - fp.Purchase_Price_Fallback) / fp.Purchase_Price_Fallback * 100.0
    ELSE NULL END AS Cost_Delta_Pct
FROM qt_demand_base_24m_v2 d
LEFT JOIN qt_last_purchase_v2 lp ON d.Item_ID = lp.Item_ID
LEFT JOIN qt_last_purchase_fallback_v2 fp ON d.Item_ID = fp.Item_ID
LEFT JOIN qt_stock_on_hand_final_v4 st ON d.Item_ID = st.Item_ID
WHERE NOT ((d.SKU IS NULL OR TRIM(d.SKU) = '') AND st.On_Hand_Qty IS NOT NULL AND st.On_Hand_Qty > 0);

/* -------------------------------------------------------------
   7b_fix_space. Unified Enrichment Snapshot v2 (space-joined columns)
   Use this variant ONLY if your join targets expose "Item ID" (space)
   instead of Item_ID. It uses qt_demand_base_24m_v2 (flattened base).
   ------------------------------------------------------------- */
SELECT
  d.Item_ID,
  d.SKU,
  d.Sales_24M_Qty,
  d.Sales_24M_Net,
  d.Avg_Demand_Used,
  lp.Last_Purchase_Date,
  lp.Last_Purchase_Price,
  fp.Purchase_Price_Fallback AS Last_Purchase_Price_Fallback,
  st.On_Hand_Qty,
  st.Current_Unit_Rate,
  CASE
    WHEN st.On_Hand_Qty IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND CAST(d.Avg_Demand_Used AS DOUBLE) > 0
      THEN st.On_Hand_Qty / d.Avg_Demand_Used
    ELSE NULL END AS Coverage_Months,
  CASE
    WHEN d.Avg_Demand_Used IS NOT NULL AND st.On_Hand_Qty IS NOT NULL THEN
      CASE WHEN (d.Avg_Demand_Used * 3) - st.On_Hand_Qty > 0 THEN (d.Avg_Demand_Used * 3) - st.On_Hand_Qty ELSE 0 END
    ELSE NULL END AS Stock_Shortfall,
  CASE
    WHEN ((st.On_Hand_Qty IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND (d.Avg_Demand_Used * 3) - st.On_Hand_Qty > 0)
       OR (st.On_Hand_Qty IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND st.On_Hand_Qty / d.Avg_Demand_Used <= 1))
      THEN 1 ELSE 0 END AS Reorder_Eligibility,
  CASE
    WHEN lp.Last_Purchase_Price IS NOT NULL AND fp.Purchase_Price_Fallback IS NOT NULL AND fp.Purchase_Price_Fallback > 0
      THEN lp.Last_Purchase_Price - fp.Purchase_Price_Fallback
    ELSE NULL END AS Cost_Delta,
  CASE
    WHEN lp.Last_Purchase_Price IS NOT NULL AND fp.Purchase_Price_Fallback IS NOT NULL AND fp.Purchase_Price_Fallback > 0
      THEN (lp.Last_Purchase_Price - fp.Purchase_Price_Fallback) / fp.Purchase_Price_Fallback * 100.0
    ELSE NULL END AS Cost_Delta_Pct
FROM qt_demand_base_24m_v2 d
LEFT JOIN qt_last_purchase_v2 lp ON d.Item_ID = lp."Item ID"
LEFT JOIN qt_last_purchase_fallback_v2 fp ON d.Item_ID = fp."Item ID"
LEFT JOIN qt_stock_on_hand_final_v4 st ON d.Item_ID = st."Item ID"
WHERE NOT ((d.SKU IS NULL OR TRIM(d.SKU) = '') AND st.On_Hand_Qty IS NOT NULL AND st.On_Hand_Qty > 0);

/* -------------------------------------------------------------
   7b_final_resolved. Unified Enrichment Snapshot v2 (resolved names)
   Based on diagnostics:
     - qt_demand_base_24m_v2 has Item_ID (underscore) OK
     - qt_last_purchase_v2 key column is "lb.Item_ID"
     - qt_last_purchase_fallback_v2 key column is Item_ID
     - qt_stock_on_hand_final_v4 key column is "s.Item_ID"
   Use this as the final enrichment to Save As your flat table.
   Adjust the date column below if your lp date shows as mLast_Purchase_Dat(e).
   ------------------------------------------------------------- */
SELECT
  d.Item_ID,
  d.SKU,
  d.Sales_24M_Qty,
  d.Sales_24M_Net,
  d.Avg_Demand_Used,
  /* lp date/price names come from qt_last_purchase_v2 preview
    Use the exact identifier shown in the picker; Zoho requires table alias */
  lp."m.Last_Purchase_Date" AS Last_Purchase_Date,
  lp.Last_Purchase_Price,
  fp.Purchase_Price_Fallback AS Last_Purchase_Price_Fallback,
  st."s.On_Hand_Qty" AS On_Hand_Qty,
  st.Current_Unit_Rate,
  CASE
    WHEN st."s.On_Hand_Qty" IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND CAST(d.Avg_Demand_Used AS DOUBLE) > 0
      THEN st."s.On_Hand_Qty" / d.Avg_Demand_Used
    ELSE NULL END AS Coverage_Months,
  CASE
    WHEN d.Avg_Demand_Used IS NOT NULL AND st."s.On_Hand_Qty" IS NOT NULL THEN
      CASE WHEN (d.Avg_Demand_Used * 3) - st."s.On_Hand_Qty" > 0 THEN (d.Avg_Demand_Used * 3) - st."s.On_Hand_Qty" ELSE 0 END
    ELSE NULL END AS Stock_Shortfall,
  CASE
    WHEN ((st."s.On_Hand_Qty" IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND (d.Avg_Demand_Used * 3) - st."s.On_Hand_Qty" > 0)
       OR (st."s.On_Hand_Qty" IS NOT NULL AND d.Avg_Demand_Used IS NOT NULL AND st."s.On_Hand_Qty" / d.Avg_Demand_Used <= 1))
      THEN 1 ELSE 0 END AS Reorder_Eligibility,
  CASE
    WHEN lp.Last_Purchase_Price IS NOT NULL AND fp.Purchase_Price_Fallback IS NOT NULL AND fp.Purchase_Price_Fallback > 0
      THEN lp.Last_Purchase_Price - fp.Purchase_Price_Fallback
    ELSE NULL END AS Cost_Delta,
  CASE
    WHEN lp.Last_Purchase_Price IS NOT NULL AND fp.Purchase_Price_Fallback IS NOT NULL AND fp.Purchase_Price_Fallback > 0
      THEN (lp.Last_Purchase_Price - fp.Purchase_Price_Fallback) / fp.Purchase_Price_Fallback * 100.0
    ELSE NULL END AS Cost_Delta_Pct
FROM qt_demand_base_24m_v2 d
LEFT JOIN qt_last_purchase_v2 lp ON d.Item_ID = lp."lb.Item_ID"
LEFT JOIN qt_last_purchase_fallback_v2 fp ON d.Item_ID = fp.Item_ID
LEFT JOIN qt_stock_on_hand_final_v4 st ON d.Item_ID = st."s.Item_ID"
WHERE NOT ((d.SKU IS NULL OR TRIM(d.SKU) = '') AND st."s.On_Hand_Qty" IS NOT NULL AND st."s.On_Hand_Qty" > 0);

/* -------------------------------------------------------------
  7b_diag_1. DIAGNOSTIC: verify column names from qt_demand_base_24m_v2
  Run this alone. If it errors on Item_ID, the flatten table did NOT
  create Item_ID as an accessible identifier. Capture the exact error text.
  ------------------------------------------------------------- */
SELECT d.Item_ID, d.SKU, d.Sales_24M_Qty, d.Sales_24M_Net, d.Avg_Demand_Used
FROM qt_demand_base_24m_v2 d
LIMIT 5;

/* -------------------------------------------------------------
  7b_diag_2. DIAGNOSTIC: quote Item_ID explicitly. Some engines require
  double quotes even after aliasing in source QT. If this works while
  7b_diag_1 fails, use quoted identifier in enrichment: d."Item_ID".
  ------------------------------------------------------------- */
SELECT d."Item_ID" AS Item_ID, d.SKU, d.Sales_24M_Qty, d.Sales_24M_Net, d.Avg_Demand_Used
FROM qt_demand_base_24m_v2 d
LIMIT 5;

/* -------------------------------------------------------------
  7b_diag_3. DIAGNOSTIC: original dotted names survived; test direct
  access without aliasing via the flatten table reference. If this works,
  the flatten table is not flattened; recreate flatten using Save As.
  ------------------------------------------------------------- */
SELECT d."sb.Item_ID" AS Item_ID, d.SKU, d."sb.Sales_24M_Qty" AS Sales_24M_Qty,
     d."sb.Sales_24M_Net" AS Sales_24M_Net, d.Avg_Demand_Used
FROM qt_demand_base_24m_v2 d
LIMIT 5;

/* -------------------------------------------------------------
  7b_diag_4. DIAGNOSTIC: confirm downstream join tables expose underscore
  or space versions. Replace with your actual table names if suffixed.
  ------------------------------------------------------------- */
SELECT lp.Item_ID AS LP_Item_ID, fp.Item_ID AS FP_Item_ID, st.Item_ID AS ST_Item_ID
FROM qt_last_purchase_v2 lp
LEFT JOIN qt_last_purchase_fallback_v2 fp ON lp.Item_ID = fp.Item_ID
LEFT JOIN qt_stock_on_hand_final_v4 st ON lp.Item_ID = st.Item_ID
LIMIT 5;

/* -------------------------------------------------------------
  7b_diag_5. DIAGNOSTIC: space version of join columns. If these return
  values while 7b_diag_4 fails, you must join on quoted space names.
  ------------------------------------------------------------- */
SELECT lp."Item ID" AS LP_Item_ID_space, fp."Item ID" AS FP_Item_ID_space, st."Item ID" AS ST_Item_ID_space
FROM qt_last_purchase_v2 lp
LEFT JOIN qt_last_purchase_fallback_v2 fp ON lp."Item ID" = fp."Item ID"
LEFT JOIN qt_stock_on_hand_final_v4 st ON lp."Item ID" = st."Item ID"
LIMIT 5;


/* -------------------------------------------------------------
   8. KPI Query (qt_dashboard_kpis) — data aware counts
   ------------------------------------------------------------- */
SELECT
  COUNT(DISTINCT CASE
      WHEN (t.SKU IS NULL OR (t.SKU NOT LIKE '800-%' AND t.SKU NOT LIKE '2000-%'))
        AND NOT (t.SKU IS NULL AND t.On_Hand_Qty IS NOT NULL AND t.On_Hand_Qty > 0)
      THEN COALESCE(
             NULLIF(TRIM(t.SKU), ''),
             '' || COALESCE(t.Item_ID, t."d.Item_ID", t.Product_ID)
           )
    END) AS Total_SKUs,
  COUNT(CASE
      WHEN (t.Avg_Demand_Used IS NOT NULL AND CAST(t.Avg_Demand_Used AS DOUBLE) > 0)
       AND (t.SKU IS NULL OR (t.SKU NOT LIKE '800-%' AND t.SKU NOT LIKE '2000-%'))
       AND NOT (t.SKU IS NULL AND t.On_Hand_Qty IS NOT NULL AND t.On_Hand_Qty > 0)
       AND ( (t.Coverage_Months IS NOT NULL AND t.Coverage_Months <= 1)
             OR (t.On_Hand_Qty IS NOT NULL AND t.Stock_Shortfall IS NOT NULL AND t.Stock_Shortfall > 0) )
      THEN 1 END) AS Reorder_Candidates,
  COUNT(CASE
      WHEN (t.Avg_Demand_Used IS NOT NULL AND CAST(t.Avg_Demand_Used AS DOUBLE) > 0)
       AND (t.On_Hand_Qty IS NOT NULL)
       AND (t.Coverage_Months IS NOT NULL AND t.Coverage_Months <= 0)
       AND (t.SKU IS NULL OR (t.SKU NOT LIKE '800-%' AND t.SKU NOT LIKE '2000-%'))
       AND NOT (t.SKU IS NULL AND t.On_Hand_Qty IS NOT NULL AND t.On_Hand_Qty > 0)
      THEN 1 END) AS Reorder_Now_Strict,
  COUNT(CASE WHEN t.On_Hand_Qty IS NOT NULL AND NOT (t.SKU IS NULL AND t.On_Hand_Qty > 0) THEN 1 END) AS Items_With_SOH,
  COUNT(CASE WHEN t.Last_Purchase_Price IS NOT NULL OR t.Last_Purchase_Price_Fallback IS NOT NULL THEN 1 END) AS Items_With_Last_Purchase,
  COUNT(CASE WHEN t.Current_Unit_Rate IS NOT NULL AND t.Current_Unit_Rate > 0 THEN 1 END) AS Items_With_Unit_Rate,
  CAST(SUM(CASE WHEN t.On_Hand_Qty IS NOT NULL AND t.Current_Unit_Rate IS NOT NULL AND t.On_Hand_Qty > 0 AND t.Current_Unit_Rate > 0
           THEN t.On_Hand_Qty * t.Current_Unit_Rate ELSE 0 END) AS DOUBLE) AS Inventory_Value_CRC,
  CAST(SUM(CASE WHEN t.On_Hand_Qty IS NOT NULL AND t.Stock_Shortfall IS NOT NULL AND t.Stock_Shortfall > 0
           THEN t.Stock_Shortfall ELSE 0 END) AS DOUBLE) AS Total_Shortfall_Units,
  CAST(AVG(CASE WHEN t.Coverage_Months IS NOT NULL THEN t.Coverage_Months END) AS DOUBLE) AS Avg_Coverage_Months,
  CAST(CASE WHEN SUM(CASE WHEN t.Coverage_Months IS NOT NULL THEN 1 ELSE 0 END) = 0 THEN NULL ELSE
      100.0 * SUM(CASE WHEN t.Coverage_Months IS NOT NULL AND t.Coverage_Months <= 1 THEN 1 ELSE 0 END)
        / SUM(CASE WHEN t.Coverage_Months IS NOT NULL THEN 1 ELSE 0 END) END AS DOUBLE) AS Pct_Below_1_Month,
  CAST(AVG(CASE WHEN t.Cost_Delta_Pct IS NOT NULL THEN t.Cost_Delta_Pct END) AS DOUBLE) AS Avg_Cost_Delta_Pct,
  MAX(COALESCE(t.Last_Purchase_Date, NULL)) AS Last_Purchase_Date_Any,
  MAX(COALESCE(t.Last_Purchase_Price, t.Last_Purchase_Price_Fallback)) AS Last_Purchase_Price_Any,
  CAST(AVG(CASE WHEN t.Avg_Demand_Used IS NOT NULL THEN t.Avg_Demand_Used END) AS DOUBLE) AS Avg_Monthly_Demand,
  CAST(SUM(COALESCE(t.Sales_24M_Qty, 0)) AS DOUBLE) AS Total_Sales_24M_Qty,
  CAST(SUM(COALESCE(t.Sales_24M_Net, 0)) AS DOUBLE) AS Total_Sales_24M_Net
FROM item_snapshot_enriched_flat_tbl t
WHERE (t.SKU IS NULL OR (t.SKU NOT LIKE '800-%' AND t.SKU NOT LIKE '2000-%'))
  AND NOT ((t.SKU IS NULL OR TRIM(t.SKU) = '') AND t.On_Hand_Qty IS NOT NULL AND t.On_Hand_Qty > 0);

/* -------------------------------------------------------------
   8b. KPI Query v2 (qt_dashboard_kpis_v2)
   Run after materializing the v2 enrichment as item_snapshot_enriched_flat_tbl_v2.
   ------------------------------------------------------------- */
/*
  NOTE on column names in item_snapshot_enriched_flat_tbl_v2
  The materialized v2 snapshot may preserve source alias prefixes like
  "d.SKU", "d.Sales_24M_Qty", "lp.Last_Purchase_Price", and
  "st.Current_Unit_Rate". To make this query resilient across older
  and newer saves, we normalize each field with COALESCE and quote
  dotted identifiers. Do NOT remove the quotes around dotted names.
  Some Zoho engines validate identifiers up-front (even inside COALESCE)
  and will error if a referenced column doesn't exist in the table. If you
  see "Invalid column 'SKU'" or similar parse-time errors, use the 8c
  dotted-only variant below which avoids referencing clean names entirely.
*/
SELECT
  COUNT(DISTINCT CASE
      WHEN (COALESCE(t.SKU, t."d.SKU") IS NULL OR (COALESCE(t.SKU, t."d.SKU") NOT LIKE '800-%' AND COALESCE(t.SKU, t."d.SKU") NOT LIKE '2000-%'))
        AND NOT (COALESCE(t.SKU, t."d.SKU") IS NULL AND t.On_Hand_Qty IS NOT NULL AND t.On_Hand_Qty > 0)
      THEN COALESCE(
             NULLIF(TRIM(COALESCE(t.SKU, t."d.SKU")), ''),
             '' || COALESCE(t.Item_ID, t."d.Item_ID", t.Product_ID)
           )
    END) AS Total_SKUs,
  COUNT(CASE
      WHEN (COALESCE(t.Avg_Demand_Used, t."d.Avg_Demand_Used") IS NOT NULL AND CAST(COALESCE(t.Avg_Demand_Used, t."d.Avg_Demand_Used") AS DOUBLE) > 0)
       AND (COALESCE(t.SKU, t."d.SKU") IS NULL OR (COALESCE(t.SKU, t."d.SKU") NOT LIKE '800-%' AND COALESCE(t.SKU, t."d.SKU") NOT LIKE '2000-%'))
       AND NOT (COALESCE(t.SKU, t."d.SKU") IS NULL AND t.On_Hand_Qty IS NOT NULL AND t.On_Hand_Qty > 0)
       AND ( (t.Coverage_Months IS NOT NULL AND t.Coverage_Months <= 1)
             OR (t.On_Hand_Qty IS NOT NULL AND t.Stock_Shortfall IS NOT NULL AND t.Stock_Shortfall > 0) )
      THEN 1 END) AS Reorder_Candidates,
  COUNT(CASE
      WHEN (COALESCE(t.Avg_Demand_Used, t."d.Avg_Demand_Used") IS NOT NULL AND CAST(COALESCE(t.Avg_Demand_Used, t."d.Avg_Demand_Used") AS DOUBLE) > 0)
       AND (t.On_Hand_Qty IS NOT NULL)
       AND (t.Coverage_Months IS NOT NULL AND t.Coverage_Months <= 0)
       AND (COALESCE(t.SKU, t."d.SKU") IS NULL OR (COALESCE(t.SKU, t."d.SKU") NOT LIKE '800-%' AND COALESCE(t.SKU, t."d.SKU") NOT LIKE '2000-%'))
       AND NOT (COALESCE(t.SKU, t."d.SKU") IS NULL AND t.On_Hand_Qty IS NOT NULL AND t.On_Hand_Qty > 0)
      THEN 1 END) AS Reorder_Now_Strict,
  COUNT(CASE WHEN t.On_Hand_Qty IS NOT NULL AND NOT (COALESCE(t.SKU, t."d.SKU") IS NULL AND t.On_Hand_Qty > 0) THEN 1 END) AS Items_With_SOH,
  COUNT(CASE WHEN COALESCE(t.Last_Purchase_Price, t."lp.Last_Purchase_Price") IS NOT NULL OR t.Last_Purchase_Price_Fallback IS NOT NULL THEN 1 END) AS Items_With_Last_Purchase,
  COUNT(CASE WHEN COALESCE(t.Current_Unit_Rate, t."st.Current_Unit_Rate") IS NOT NULL AND COALESCE(t.Current_Unit_Rate, t."st.Current_Unit_Rate") > 0 THEN 1 END) AS Items_With_Unit_Rate,
  CAST(SUM(CASE WHEN t.On_Hand_Qty IS NOT NULL AND COALESCE(t.Current_Unit_Rate, t."st.Current_Unit_Rate") IS NOT NULL AND t.On_Hand_Qty > 0 AND COALESCE(t.Current_Unit_Rate, t."st.Current_Unit_Rate") > 0
           THEN t.On_Hand_Qty * COALESCE(t.Current_Unit_Rate, t."st.Current_Unit_Rate") ELSE 0 END) AS DOUBLE) AS Inventory_Value_CRC,
  CAST(SUM(CASE WHEN t.On_Hand_Qty IS NOT NULL AND t.Stock_Shortfall IS NOT NULL AND t.Stock_Shortfall > 0
           THEN t.Stock_Shortfall ELSE 0 END) AS DOUBLE) AS Total_Shortfall_Units,
  CAST(AVG(CASE WHEN t.Coverage_Months IS NOT NULL THEN t.Coverage_Months END) AS DOUBLE) AS Avg_Coverage_Months,
  CAST(CASE WHEN SUM(CASE WHEN t.Coverage_Months IS NOT NULL THEN 1 ELSE 0 END) = 0 THEN NULL ELSE
      100.0 * SUM(CASE WHEN t.Coverage_Months IS NOT NULL AND t.Coverage_Months <= 1 THEN 1 ELSE 0 END)
        / SUM(CASE WHEN t.Coverage_Months IS NOT NULL THEN 1 ELSE 0 END) END AS DOUBLE) AS Pct_Below_1_Month,
  CAST(AVG(CASE WHEN t.Cost_Delta_Pct IS NOT NULL THEN t.Cost_Delta_Pct END) AS DOUBLE) AS Avg_Cost_Delta_Pct,
  MAX(COALESCE(t.Last_Purchase_Date, NULL)) AS Last_Purchase_Date_Any,
  MAX(COALESCE(t.Last_Purchase_Price, t."lp.Last_Purchase_Price", t.Last_Purchase_Price_Fallback)) AS Last_Purchase_Price_Any,
  CAST(AVG(CASE WHEN COALESCE(t.Avg_Demand_Used, t."d.Avg_Demand_Used") IS NOT NULL THEN COALESCE(t.Avg_Demand_Used, t."d.Avg_Demand_Used") END) AS DOUBLE) AS Avg_Monthly_Demand,
  CAST(SUM(COALESCE(t.Sales_24M_Qty, t."d.Sales_24M_Qty", 0)) AS DOUBLE) AS Total_Sales_24M_Qty,
  CAST(SUM(COALESCE(t.Sales_24M_Net, t."d.Sales_24M_Net", 0)) AS DOUBLE) AS Total_Sales_24M_Net
FROM item_snapshot_enriched_flat_tbl_v2 t
WHERE (COALESCE(t.SKU, t."d.SKU") IS NULL OR (COALESCE(t.SKU, t."d.SKU") NOT LIKE '800-%' AND COALESCE(t.SKU, t."d.SKU") NOT LIKE '2000-%'))
  AND NOT ((COALESCE(t.SKU, t."d.SKU") IS NULL OR TRIM(COALESCE(t.SKU, t."d.SKU")) = '') AND t.On_Hand_Qty IS NOT NULL AND t.On_Hand_Qty > 0);

/* -------------------------------------------------------------
   8c. KPI Query v2 (qt_dashboard_kpis_v2_dotted)
   Use this if 8b errors with Invalid column 'SKU' (strict identifier
   validation). This version references only the dotted/prefixed names
   that appear in item_snapshot_enriched_flat_tbl_v2 exports.
   ------------------------------------------------------------- */
SELECT
  COUNT(DISTINCT CASE
      WHEN (t."d.SKU" IS NULL OR (t."d.SKU" NOT LIKE '800-%' AND t."d.SKU" NOT LIKE '2000-%'))
        AND NOT (t."d.SKU" IS NULL AND t.On_Hand_Qty IS NOT NULL AND t.On_Hand_Qty > 0)
      THEN COALESCE(
             NULLIF(TRIM(t."d.SKU"), ''),
             '' || COALESCE(t."d.Item_ID", t.Product_ID)
           )
    END) AS Total_SKUs,
  COUNT(CASE
      WHEN (t."d.Avg_Demand_Used" IS NOT NULL AND CAST(t."d.Avg_Demand_Used" AS DOUBLE) > 0)
       AND (t."d.SKU" IS NULL OR (t."d.SKU" NOT LIKE '800-%' AND t."d.SKU" NOT LIKE '2000-%'))
       AND NOT (t."d.SKU" IS NULL AND t.On_Hand_Qty IS NOT NULL AND t.On_Hand_Qty > 0)
       AND ( (t.Coverage_Months IS NOT NULL AND t.Coverage_Months <= 1)
             OR (t.On_Hand_Qty IS NOT NULL AND t.Stock_Shortfall IS NOT NULL AND t.Stock_Shortfall > 0) )
      THEN 1 END) AS Reorder_Candidates,
  COUNT(CASE
      WHEN (t."d.Avg_Demand_Used" IS NOT NULL AND CAST(t."d.Avg_Demand_Used" AS DOUBLE) > 0)
       AND (t.On_Hand_Qty IS NOT NULL)
       AND (t.Coverage_Months IS NOT NULL AND t.Coverage_Months <= 0)
       AND (t."d.SKU" IS NULL OR (t."d.SKU" NOT LIKE '800-%' AND t."d.SKU" NOT LIKE '2000-%'))
       AND NOT (t."d.SKU" IS NULL AND t.On_Hand_Qty IS NOT NULL AND t.On_Hand_Qty > 0)
      THEN 1 END) AS Reorder_Now_Strict,
  COUNT(CASE WHEN t.On_Hand_Qty IS NOT NULL AND NOT (t."d.SKU" IS NULL AND t.On_Hand_Qty > 0) THEN 1 END) AS Items_With_SOH,
  COUNT(CASE WHEN COALESCE(t."lp.Last_Purchase_Price", t.Last_Purchase_Price_Fallback) IS NOT NULL THEN 1 END) AS Items_With_Last_Purchase,
  COUNT(CASE WHEN COALESCE(t."st.Current_Unit_Rate", NULL) IS NOT NULL AND COALESCE(t."st.Current_Unit_Rate", NULL) > 0 THEN 1 END) AS Items_With_Unit_Rate,
  CAST(SUM(CASE WHEN t.On_Hand_Qty IS NOT NULL AND COALESCE(t."st.Current_Unit_Rate", NULL) IS NOT NULL AND t.On_Hand_Qty > 0 AND COALESCE(t."st.Current_Unit_Rate", NULL) > 0
           THEN t.On_Hand_Qty * COALESCE(t."st.Current_Unit_Rate", NULL) ELSE 0 END) AS DOUBLE) AS Inventory_Value_CRC,
  CAST(SUM(CASE WHEN t.On_Hand_Qty IS NOT NULL AND t.Stock_Shortfall IS NOT NULL AND t.Stock_Shortfall > 0
           THEN t.Stock_Shortfall ELSE 0 END) AS DOUBLE) AS Total_Shortfall_Units,
  CAST(AVG(CASE WHEN t.Coverage_Months IS NOT NULL THEN t.Coverage_Months END) AS DOUBLE) AS Avg_Coverage_Months,
  CAST(CASE WHEN SUM(CASE WHEN t.Coverage_Months IS NOT NULL THEN 1 ELSE 0 END) = 0 THEN NULL ELSE
      100.0 * SUM(CASE WHEN t.Coverage_Months IS NOT NULL AND t.Coverage_Months <= 1 THEN 1 ELSE 0 END)
        / SUM(CASE WHEN t.Coverage_Months IS NOT NULL THEN 1 ELSE 0 END) END AS DOUBLE) AS Pct_Below_1_Month,
  CAST(AVG(CASE WHEN t.Cost_Delta_Pct IS NOT NULL THEN t.Cost_Delta_Pct END) AS DOUBLE) AS Avg_Cost_Delta_Pct,
  MAX(COALESCE(t.Last_Purchase_Date, NULL)) AS Last_Purchase_Date_Any,
  MAX(COALESCE(t."lp.Last_Purchase_Price", t.Last_Purchase_Price_Fallback)) AS Last_Purchase_Price_Any,
  CAST(AVG(CASE WHEN t."d.Avg_Demand_Used" IS NOT NULL THEN t."d.Avg_Demand_Used" END) AS DOUBLE) AS Avg_Monthly_Demand,
  CAST(SUM(COALESCE(t."d.Sales_24M_Qty", 0)) AS DOUBLE) AS Total_Sales_24M_Qty,
  CAST(SUM(COALESCE(t."d.Sales_24M_Net", 0)) AS DOUBLE) AS Total_Sales_24M_Net
FROM item_snapshot_enriched_flat_tbl_v2 t
WHERE (t."d.SKU" IS NULL OR (t."d.SKU" NOT LIKE '800-%' AND t."d.SKU" NOT LIKE '2000-%'))
  AND NOT ((t."d.SKU" IS NULL OR TRIM(t."d.SKU") = '') AND t.On_Hand_Qty IS NOT NULL AND t.On_Hand_Qty > 0);

/* End of bundle */
