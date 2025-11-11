# Pantera Inventory & Reorder Dashboard Guide (Zoho Analytics)

This guide walks you through building the dashboards now that the enrichment + KPI query tables exist. It is tailored to the SQL bundle in `queries.sql` and the materialized flat snapshot (`item_snapshot_enriched_flat_tbl_v2`).

---
## 1. Source Tables You Should Already Have
Create (or verify) these Query Tables are saved and refreshed successfully:

Required core:
- `qt_last_purchase_v2`  (most recent purchase price + date per item)  
- `qt_last_purchase_fallback_v2` (fallback unit price)  
- `qt_stock_on_hand_final_v4` (On_Hand_Qty + Current_Unit_Rate)  
- `qt_demand_base_24m_v2` (24M sales + Avg_Demand_Used)  
- `qt_item_snapshot_enriched_v2` (joins above)  
- Saved As (Materialized): `item_snapshot_enriched_flat_tbl_v2` (your canonical flat)  
- KPI Queries: `qt_dashboard_kpis_v2` (resilient), `qt_dashboard_kpis_v2_dotted` (fallback), `qt_dashboard_kpis_v2_policy_matrix` (multi-policy months selector)

Optional diagnostics:
- `qt_dashboard_kpis` (legacy)  
- `qt_item_snapshot_enriched_v2_alt*` variants (only keep if needed)

If any are missing, create them before proceeding. Avoid editing tables with downstream locks; create suffixed versions (e.g. `_v2`, `_v4`).

---
## 2. Data Refresh Strategy
Because the flat snapshot is derived from upstream Query Tables:
1. Schedule refresh for base sources (imports) first: sales, inventory, PO items.  
2. Stagger Query Table refreshes (e.g., +5 minutes) for: last purchase base → last purchase v2 → stock on hand final v4 → demand base v2 → enrichment v2 → flat table → KPI tables.  
3. If refresh chaining causes deadlocks, clone the locked QT to a new name (e.g. append `_v2`).
4. For large tables, enable incremental import if available (otherwise full refresh is fine; dataset size is moderate).  

---
## 3. Normalized Key Pattern
You will reference items using a unified label:
```
COALESCE(NULLIF(TRIM(SKU), ''), '' || Item_ID)
```
Keep this consistent in custom formulas or widgets to avoid duplicate counts.

---
## 4. Building the Dashboard Layout
Recommended structure: use a single dashboard with sections instead of separate tabs, unless you expect >10 widgets. A single page keeps filtering (e.g., policy_months) coherent and easier to maintain. If you outgrow it, split into two tabs: “Overview KPIs” and “Working Panels”.

Suggested sections on one dashboard:
1) High-Level Metrics (KPI cards)
  - From `qt_dashboard_kpis_v2_policy_matrix` add cards for: Total SKUs, Reorder Candidates, Reorder Now Strict, Pct Below Policy, Inventory Value CRC.
2) Policy Selector
  - Add a filter on `policy_months` (from the same matrix query). Link it to the KPI cards. Default to 1.5 or 2.0 based on preference.
3) Coverage Distribution
  - Chart widget (Histogram/Bar) using `item_snapshot_enriched_flat_tbl_v2` with binned `Coverage_Months` (custom grouping).
4) Reorder Table (action list)
  - Table over `item_snapshot_enriched_flat_tbl_v2` showing SKU/Item_ID, On_Hand_Qty, Avg_Demand_Used, Coverage, Current_Unit_Rate, dynamic shortfall (formula). Filter to rows where dynamic shortfall > 0 OR Coverage <= selected policy.
5) Exception Panels
  - Items with NULL avg demand but stock (>0).
  - Items with extreme coverage (> policy * 6) for trimming and buying pauses.
6) Purchase Recency
  - Items with NULL Last_Purchase_Date but non-null price fallback.
7) Cost Change Watch
  - Items with Cost_Delta_Pct above threshold (e.g., > 10%).

---
## 5. Implementing the Policy Months Selector
There is no SQL variable binding in Query Tables; we pre-computed rows per policy in `qt_dashboard_kpis_v2_policy_matrix`.

Steps:
1. Create a Dashboard Filter on column `policy_months` sourced from the policy matrix QT.  
2. Link this filter to the KPI matrix widget and any charts that should pivot by policy.  
3. For item-level tables (based on `item_snapshot_enriched_flat_tbl_v2`), replicate logic with a formula column (see dynamic shortfall below) using the selected policy value.  
   - If Zoho dashboards cannot inject the policy numerically into formulas, display the matrix table filtered to one policy and omit dynamic row-level recalculation.  
4. (Advanced) Create additional KPI widgets for each policy (1.0/1.5/2.0/3.0) and allow user to toggle visibility if interactive filter is not flexible enough.

---
## 6. Dynamic Shortfall vs. Materialized Shortfall
Current enrichment uses fixed 3-month buffer: `Stock_Shortfall = max( (Avg_Demand_Used*3) - On_Hand_Qty, 0 )`.

To display dynamic shortfall for the selected policy without rebuilding the snapshot:
Add a Table Widget over `item_snapshot_enriched_flat_tbl_v2` with a Custom Formula Column:
```
CASE WHEN Avg_Demand_Used IS NOT NULL AND On_Hand_Qty IS NOT NULL AND ${PolicyMonths} IS NOT NULL THEN 
  CASE WHEN (${PolicyMonths} * Avg_Demand_Used) - On_Hand_Qty > 0 THEN (${PolicyMonths} * Avg_Demand_Used) - On_Hand_Qty ELSE 0 END
ELSE NULL END
```
Replace `${PolicyMonths}` with the dashboard filter binding if supported. If binding is not allowed, rely on the precomputed matrix and keep the static 3-month shortfall visible OR maintain multiple snapshots for different policies (only if business requires).

---
## 5.1 Detailed Zoho Analytics UI Walkthrough
The steps below use the new UI; menu labels may vary slightly.

1) Create the Dashboard container
  - Analytics workspace → Create → Dashboard → Name it “Inventory & Reorder”.

2) Add the policy KPI matrix
  - Click Add Widget → Chart/Table → Choose `qt_dashboard_kpis_v2_policy_matrix`.
  - Use a Summary/Table widget initially to verify the rows for policy_months (1.0/1.5/2.0/3.0).
  - Add KPI Cards: Add Widget → KPI → Data = same query; Value = Total_SKUs, Reorder_Candidates, Reorder_Now_Strict, Pct_Below_Policy, Inventory_Value_CRC.
  - For each KPI card, set Aggregation = Value (no extra grouping), and add a subtitle “Policy: ${policy_months}”.

3) Add the policy filter
  - On the dashboard top bar, Add Filter → Column Filter → Source: `qt_dashboard_kpis_v2_policy_matrix` → Column: `policy_months`.
  - Style: Dropdown (single select). Default value: 1.5 or 2.0.
  - Apply To: Select all KPI widgets that read from the policy matrix.

4) Add Coverage histogram
  - Add Widget → Chart → Bar/Histogram → Source: `item_snapshot_enriched_flat_tbl_v2`.
  - X-Axis: Custom formula to bucket coverage, e.g. `CASE WHEN Coverage_Months IS NULL THEN 'Unknown' WHEN Coverage_Months < 0 THEN '< 0' WHEN Coverage_Months < 1 THEN '0-1' WHEN Coverage_Months < 2 THEN '1-2' WHEN Coverage_Months < 3 THEN '2-3' WHEN Coverage_Months < 6 THEN '3-6' WHEN Coverage_Months < 12 THEN '6-12' ELSE '12+' END`.
  - Y-Axis: Count of distinct normalized key (see Section 3). Use “Aggregate → Unique Count” on the formula `COALESCE(NULLIF(TRIM(SKU), ''), '' || Item_ID)` if supported, or COUNT of records if de-duplicated.
  - Link Filter: If you need policy-sensitive view, keep this unfiltered by policy; Coverage is intrinsic. Or add a derived “At/Below Policy” flag as a report-specific formula using a constant that mirrors the selected policy.

5) Build the Reorder table
  - Add Widget → Table → Source: `item_snapshot_enriched_flat_tbl_v2`.
  - Columns: SKU, Item_ID, On_Hand_Qty, Avg_Demand_Used, Coverage_Months, Current_Unit_Rate, Last_Purchase_Price_Fallback, `lp.Last_Purchase_Price` (if present), Sales_24M_Qty.
  - Add a custom column: Dynamic_Shortfall = `CASE WHEN Avg_Demand_Used IS NOT NULL AND On_Hand_Qty IS NOT NULL THEN GREATEST( (${PolicyMonths} * Avg_Demand_Used) - On_Hand_Qty, 0 ) END`.
  - If binding `${PolicyMonths}` isn’t supported, omit the dynamic column and instead show the precomputed `Stock_Shortfall` (3-month policy) or build separate tables per policy.
  - Filters on table: `(Dynamic_Shortfall > 0) OR (Coverage_Months <= ${PolicyMonths})` (use Stock_Shortfall and <=1 if dynamic binding isn’t available).

6) Exceptions & hygiene widgets
  - Table: Items with (Avg_Demand_Used IS NULL AND On_Hand_Qty > 0).
  - Table: Items with (Coverage_Months > ${PolicyMonths} * 6) (or a fixed threshold) to review stocking policies.
  - Table: Items with (Last_Purchase_Date IS NULL AND COALESCE(`lp.Last_Purchase_Price`, Last_Purchase_Price_Fallback) IS NOT NULL).

7) Finishing touches
  - Arrange KPI cards top row; charts second row; action tables below.
  - Save the dashboard and test the policy_months filter toggling (1.0/1.5/2.0/3.0) — KPIs should update immediately.
  - Share permissions: View-only for most users; edit rights for admins. Enable scheduled email/PDF exports of the KPI matrix if needed.

---
## 5.2 Widget Picker Mapping (matches your left panel)
Use these presets from the “Widget” tab and when needed add text from the “Elements” tab.

- Label Value (single):
  - Use for: Total SKUs, Inventory Value CRC, Total Shortfall Units.
  - Why: Clean single-number display with optional subtitle.

- Label Value 2 (dual):
  - Use for: Reorder Now Strict with a second value showing % of Total (see note below).
  - Tip: If KPI card cannot compute % inline, either add a formula column in the policy matrix QT (e.g., `Reorder_Share_Pct`), or use a tiny “Text” element next to the card to display the percent.

- Label Value 3 (triple):
  - Use for: Reorder Candidates with secondary/tertiary values like Pct_Below_Policy and Reorder share.
  - Layout tip: Keep secondary labels short, e.g., “%Below” and “%Reord”.

- Bullet Chart:
  - Use for: Pct_Below_Policy vs target threshold (e.g., target 25%).
  - Configure ranges: Red 50–100, Amber 25–50, Green 0–25 (adjust to policy).

- Dial / Full Dial:
  - Optional visual alternative to show Pct_Below_Policy or Reorder share.
  - Use sparingly; gauges consume more space than KPI cards.

Elements tab (text and helpers):
- Title: Section headers like “Overview KPIs” or “Reorder Workbench”.
- Paragraph: One‑line instructions for users (e.g., “Use the Policy filter to switch buffer months”).
- Rich Text: For links and styled bullets (SOPs, glossary).
- Image: Company logo or legend.
- Embed: Link to external SOP, spreadsheet, or Webclient iframes (if allowed by policy).

Note on “% of Total” in dual/triple KPI presets: If the card requires a physical column for the second/third value, add it to the policy matrix query, for example:
```
SELECT ..., 
  100.0 * Reorder_Candidates / NULLIF(Total_SKUs,0) AS Reorder_Share_Pct,
  100.0 * Reorder_Now_Strict / NULLIF(Total_SKUs,0) AS ReorderNow_Share_Pct
FROM qt_dashboard_kpis_v2_policy_matrix;
```
Or create a Report over the matrix and add a Formula column there, then feed the KPI from that Report.

---
## 7. KPI Card Definitions (Reference)
| KPI | Source Query | Formula |
|-----|--------------|---------|
| Total SKUs | Policy matrix or flat | Distinct normalized key excluding blank SKU with stock only placeholder |
| Reorder Candidates | Policy matrix | Coverage <= policy OR dynamic shortfall > 0 AND demand > 0 |
| Reorder Now Strict | Policy matrix | Coverage <= 0 AND demand > 0 |
| Pct Below Policy | Policy matrix | (% of items with coverage <= policy among items with coverage) |
| Inventory Value CRC | Policy matrix / flat | SUM(On_Hand_Qty * Current_Unit_Rate) (dedupe if duplicates appear) |
| Total Shortfall Units | Policy matrix | SUM(max( (policy*Avg_Demand_Used - On_Hand_Qty), 0 )) |

---
## 7.1 KPI & Panel Widget Catalog (Exact UI Choices)
Use these selections in Zoho Analytics when adding widgets. They assume the current UI labels; adjust if Zoho renames any option.

### A. High-Level KPI Row
1. Total SKUs
  - Widget Type: KPI Card
  - Source: `qt_dashboard_kpis_v2_policy_matrix`
  - Value Column: `Total_SKUs`
  - Aggregation: NONE (already aggregated)
  - Subtitle: `Policy ${policy_months}`
  - Conditional Formatting: Optional (Green if > 4500, Amber 4000–4500, Red < 4000)

2. Reorder Candidates
  - Widget Type: KPI Card
  - Source: `qt_dashboard_kpis_v2_policy_matrix`
  - Value: `Reorder_Candidates`
  - Trend Indicator: Enable trend using previous period snapshot (requires historical snapshot table)
  - Threshold Coloring: Red if > (Total_SKUs * 0.9), Amber 0.6–0.9, Green < 0.6 (tune)

3. Reorder Now Strict
  - Widget Type: KPI Card
  - Source: `qt_dashboard_kpis_v2_policy_matrix`
  - Value: `Reorder_Now_Strict`
  - Secondary Metric (Optional): % of Total = `Reorder_Now_Strict / Total_SKUs`

4. Pct Below Policy
  - Widget Type: KPI Card (Percentage style)
  - Source: `qt_dashboard_kpis_v2_policy_matrix`
  - Value: `Pct_Below_Policy`
  - Display: Suffix `%`, decimals: 1
  - Ranges: Green < 30%, Amber 30–50%, Red > 50% (or adapt to business tolerance)

5. Inventory Value CRC
  - Widget Type: KPI Card (Currency)
  - Source: `qt_dashboard_kpis_v2_policy_matrix`
  - Value: `Inventory_Value_CRC`
  - Format: Currency (Custom) Code: `CRC`, thousands separator ON
  - Optional Sparkline: Off (large number)

6. Total Shortfall Units
  - Widget Type: KPI Card
  - Source: `qt_dashboard_kpis_v2_policy_matrix`
  - Value: `Total_Shortfall_Units`
  - Interpretation: Units needed to meet chosen policy buffer.

### B. Coverage Distribution Chart
  - Widget Type: Bar Chart / Column Chart
  - Source: `item_snapshot_enriched_flat_tbl_v2`
  - X: Coverage bucket formula (Section 4 step 4)
  - Y: Count Distinct normalized key formula
  - Sort: Bucket order (custom sequence): Unknown,<0,0-1,1-2,2-3,3-6,6-12,12+
  - Color: Single color palette or gradient by bucket
  - Tooltip: Show raw distinct count + % of total (add formula: count / total_SKUs * 100)

### C. Reorder Action Table
  - Widget Type: Table
  - Source: `item_snapshot_enriched_flat_tbl_v2`
  - Columns: SKU, d.Item_ID, On_Hand_Qty, Avg_Demand_Used, Coverage_Months, Current_Unit_Rate, Sales_24M_Qty, Stock_Shortfall, Cost_Delta_Pct
  - Custom Column: `Dynamic_Shortfall` (if binding supported)
  - Row Conditional Formatting: Highlight rows where Coverage_Months <= policy OR Dynamic_Shortfall > 0 (background pale red)
  - Sorting Default: Coverage_Months ascending

### D. Null Demand Panel
  - Widget Type: Table (compact)
  - Filter: Avg_Demand_Used IS NULL AND On_Hand_Qty > 0
  - Columns: SKU, On_Hand_Qty, Coverage_Months (will be NULL), Current_Unit_Rate
  - Purpose: Feeds data cleanup; users decide whether to backfill demand

### E. Extreme Coverage Panel
  - Widget Type: Table
  - Filter: Coverage_Months > (${policy_months} * 6) OR Coverage_Months > 18 if binding unavailable
  - Columns: SKU, Coverage_Months, Avg_Demand_Used, On_Hand_Qty
  - Conditional Formatting: Coverage_Months cell colored orange > 12, red > 24

### F. Purchase Recency Panel
  - Widget Type: Table
  - Filter: Last_Purchase_Date IS NULL AND (lp.Last_Purchase_Price OR Last_Purchase_Price_Fallback) IS NOT NULL
  - Columns: SKU, d.Item_ID, Last_Purchase_Price_Fallback, lp.Last_Purchase_Price, On_Hand_Qty
  - Add formula Age_Days later if date populated.

### G. Cost Change Watch
  - Widget Type: Table or KPI Card (if just count)
  - Filter: Cost_Delta_Pct > 10
  - KPI Variant: Count Distinct SKU under threshold and above threshold (two small KPIs)

### H. Policy Matrix Reference Table (Optional)
  - Widget Type: Table
  - Source: `qt_dashboard_kpis_v2_policy_matrix`
  - Columns: policy_months, Total_SKUs, Reorder_Candidates, Reorder_Now_Strict, Pct_Below_Policy, Inventory_Value_CRC, Total_Shortfall_Units
  - Use for quick comparisons before choosing default policy.

### I. Drill-Through (Optional Future)
  - Add right-click drill on Coverage bucket → opens filtered Reorder table.
  - Precondition: Enable drill mapping in the chart options.

### J. Export Snapshot
  - Use Export → PDF for KPI row + action table.
  - For CSV of reorder list: Create a Report from the Reorder table with same filters and export from Report view (dashboard export may not include custom formula definitions cleanly).

### Widget Performance Considerations
| Widget | Performance Risk | Mitigation |
|--------|------------------|------------|
| KPI Cards (matrix) | Low | Matrix pre-aggregated |
| Reorder Table | Medium (full scan) | Add pagination (50 rows) and selective columns |
| Coverage Chart | Low | Bucketing reduces cardinality |
| Exception Panels | Low | Narrow filters |
| Policy Matrix Table | Very Low | Already aggregated rows (<=4) |

If latency appears: Verify Query Table refresh schedule; avoid live calculations (multiple nested formulas) in each widget.

---

---
## 8. Performance & Hygiene Tips
- Avoid COUNT(*) on large tables; always COUNT(DISTINCT normalized key).  
- Cast numeric text once in upstream QT (already done) to avoid repeated CAST in dashboard formulas.  
- If you see inflated Inventory_Value_CRC, verify duplicates by grouping on (Item_ID, SKU). Add a de-dup QT if needed.  
- Keep no more than 2–3 enrichment variants to reduce confusion; archive unused 7c/diagnostic blocks once stable.  

---
## 9. Adding a De-Duplicated View (Optional)
If duplicates arise, create `qt_item_snapshot_dedup_v2`:
```
SELECT 
  "d.Item_ID" AS Item_ID,
  MIN("d.SKU") AS SKU,
  MAX(On_Hand_Qty) AS On_Hand_Qty,
  MAX(Current_Unit_Rate) AS Current_Unit_Rate,
  MAX(Avg_Demand_Used) AS Avg_Demand_Used,
  MAX(Coverage_Months) AS Coverage_Months,
  MAX(Stock_Shortfall) AS Stock_Shortfall,
  MAX(Last_Purchase_Price_Fallback) AS Last_Purchase_Price_Fallback,
  MAX("lp.Last_Purchase_Price") AS Last_Purchase_Price
FROM item_snapshot_enriched_flat_tbl_v2
GROUP BY "d.Item_ID";
```
Point KPI queries to this if necessary.

---
## 10. Handling Missing Purchase Dates
- If `Last_Purchase_Date` remains NULL for all rows, confirm the quoted dotted column (e.g. `m.Last_Purchase_Date`) in the source last purchase QT.  
- Patch enrichment selecting the exact dotted identifier and re-materialize.  
- Add a dashboard tile: count of items lacking Last_Purchase_Date but having Last_Purchase_Price_Fallback.

---
## 11. Exporting Dashboard Snapshots
- Use Zoho's dashboard export (CSV/PDF) for KPI matrix.  
- For a combined export including dynamic shortfall: build a report view joining policy matrix row (filtered to chosen policy) back to the item table with a parameter.  
- If dynamic parameter binding is unavailable, create separate export views per common policy (e.g., `reorder_export_policy_1_5`, `reorder_export_policy_2_0`).

---
## 12. Rollout Checklist
1. Confirm all Query Tables refresh without error.  
2. Materialize `item_snapshot_enriched_flat_tbl_v2`.  
3. Validate column presence (dotted prefixes).  
4. Run KPI policy matrix query manually; verify rows for each policy.  
5. Build dashboard with filter on policy_months.  
6. Add KPI cards (Total SKUs, Reorder Candidates, etc.).  
7. Add Reorder Table using current policy logic.  
8. Add Coverage distribution chart.  
9. Add hygiene + cost change panels.  
10. Test exports.  
11. Schedule refresh chain.  
12. Document for users (link this guide).

---
## 13. Future Enhancements
- Currency toggle (CRC ↔ USD) using exchange rate from PO tables.  
- Seasonal demand adjustment (Avg_Demand_Used weighted by last 6M).  
- Safety stock factor per supplier category.  
- Policy slider (if Zoho adds UI numeric parameter binding).  
- Age of last purchase (DATEDIFF(today, Last_Purchase_Date)).

---
## 14. Quick FAQ
**Q: Why does Reorder Candidates sometimes equal Total SKUs?**  
A: With a high buffer (e.g., 3 months) and low average demand, most items fall below policy threshold; use a smaller policy or dynamic shortfall to refine.

**Q: Inventory Value seems huge—normal?**  
A: Values are in CRC. If you expected USD, multiply by (1 / ExchangeRate) after adding that column.

**Q: Why are purchase dates blank?**  
A: Source last purchase QT column naming mismatch; reselect the correct dotted date column and re-materialize.

---
## 14.1 Troubleshooting KPI Matrix
Use these checks when the policy matrix outputs look off:

| Symptom | Likely Cause | Quick Fix |
|---------|--------------|-----------|
| Reorder_Candidates = Total_SKUs for all policies | Candidate logic too broad (NULL coverage treated as candidate; coverage universally below largest policy) | Tighten logic: require Avg_Demand_Used > 0 AND Coverage_Months IS NOT NULL; optionally drop NULL coverage from candidate rule. Re‑save matrix. |
| Avg_Coverage_Months changes when policy changes | Policy dimension leaking into average (e.g., filtering coverage inside CASE by policy) | Ensure Avg_Coverage_Months formula does not reference policy_months; use simple AVG over qualifying rows. |
| Last_Purchase_Date_Any NULL for all rows | Enrichment selecting wrong identifier (e.g., missing lp."m.Last_Purchase_Date") | Inspect last purchase QT preview; copy exact quoted column name into enrichment SELECT; re-materialize flat table. |
| Inventory_Value_CRC unexpectedly large | CRC values interpreted as USD or duplicates inflating quantity | Group by Item_ID to inspect duplicates; create dedup QT; add USD conversion using exchange rate. |
| Pct_Below_Policy = 100% | Coverage_Months for all items <= policy or coverage NULL counted as below | Exclude NULL coverage from denominator (already done in provided SQL) OR lower policy buffer; validate coverage distribution chart. |
| Total_Shortfall_Units extremely high | Policy multiplier applied to items with very low or zero demand | Add demand threshold (Avg_Demand_Used >= 0.2) in shortfall CASE to filter noise. |

### Verification Script (Local)
Run the PowerShell validator on the exported `qt_dashboard_kpis_v2_policy_matrix.csv`:
```
pwsh ./tools/diagnostics/validate_policy_matrix.ps1 -Path ./data/qt_dashboard_kpis_v2_policy_matrix.csv
```
It will flag monotonicity issues (e.g., Reorder_Now_Strict increasing with higher policy unexpectedly) and missing date/price coverage.

### Adjusting Candidate Logic
If you need stricter candidates:
```
CASE WHEN Avg_Demand_Used > 0
  AND Coverage_Months IS NOT NULL
  AND Coverage_Months <= policy_months
  THEN 1 ELSE 0 END
```
Add OR Stock_Shortfall > 0 for buffer‑based inclusion.

### Recording Changes
Append adjustments to `queries.sql` with a dated comment block:
```
/* 2025-11-11: Tightened candidate logic to exclude NULL coverage */
```
Maintain one active matrix QT and archive prior versions if semantics change.

---
## 15. Support and Iteration
Keep a small changelog in `queries.sql` when adjusting policy logic or enrichment formulas; version KPI queries (e.g., `_v3`) only when semantics change.

---
End of guide.
