Zoho Analytics SQL — Enrichment and KPI Queries

This folder contains copy‑pasteable SQL for Zoho Analytics to build the item enrichment and KPI dataset. All queries are written to be “Zoho‑safe”:

- Use only /* ... */ style comments (no //) to avoid parser issues.
- Avoid unsupported functions (e.g., GREATEST); use CASE instead.
- Cast currency text like "CRC 24,860.00" to numbers with nested REPLACE + CAST.
- Always prefix columns with a table alias when you define one (e.g., t.SKU).

Execution order (recommended):

1) qt_last_purchase_base
2) qt_last_purchase
3) qt_last_purchase_fallback
4) qt_stock_on_hand (raw)
5) qt_stock_on_hand_final
6) qt_demand_base_24m (or your existing qt_demand_backfill_v2)
7) qt_item_snapshot_enriched_vX (final)
8) Materialize final as a Table: item_snapshot_enriched_flat_tbl
9) Build KPI query (qt_dashboard_kpis) pointing at the materialized table.

Tips
- If Zoho shows “maximum of 5 levels of Query over Query tables,” open the intermediate QTs and Save As → Table, then update downstream FROM clauses to use those tables.
- If you see “Encountered: AND” errors, it’s usually a stray comment or a dangling AND after removing a filter. Ensure WHERE clauses have proper preceding predicates and comments use /* ... */.
