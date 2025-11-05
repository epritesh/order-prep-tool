# Pantera Order Preparation Tool — AI Coding Instructions

These rules help AI agents work productively in this repo. Keep guidance concrete and tied to actual files and patterns here.

## Architecture at a glance
- Data-first repo with static webclient (no backend). Frontend lives in `webclient/` and loads CSVs from `/data/` or repo root using PapaParse.
- Primary datasets (UTF-8 CSV):
	- `SalesHistory_Updated_Oct2025.csv` (~21,620 rows): monthly sales, key fields: `Item_ID, Item_Name, Month_Year, Total_Quantity, Net_Sales, Item_SKU, CF_Supplier_Code`.
	- `Purchase_Order.csv` (~18,806 rows): PO lines, key fields: `Purchase Order Date, Purchase Order Status, Item Price, Product ID, SKU, QuantityOrdered, QuantityReceived`.
	- `Items.csv` (to be provided): inventory master with at least `Item_ID/Product ID, Item_Name, SKU, Available_Stock, Cost`.
- Webclient renders a spreadsheet per item with: last 24 months sales, outstanding PO qty, available stock, last purchase price, and inventory cost.

## Webclient conventions
- Entry: `webclient/index.html`; logic: `webclient/assets/app.js`; styles: `webclient/assets/style.css`.
- Data path is fixed to `data/` relative to `webclient/` (put CSVs in `webclient/data/`).
- Header normalization: app supports bilingual/variant headers. Accessors unify names like `Item_ID` vs `Product ID`, `Item_SKU` vs `SKU`, `Available_Stock` vs `AvailableQuantity`, and `Cost` vs `Rate/Average Cost`.
- Join key: composite of `SKU` and `Item_ID/Product ID` when both exist; otherwise falls back to either if available, else `Item_Name`.
- Sales window: computed dynamically for the last 24 months from the current month (uses `Month_Year` format `YYYY-MM`).

## Business rules implemented
- Outstanding PO qty = max(0, `QuantityOrdered − QuantityReceived`) summed per item, excluding PO lines with status `Billed` or `Closed`.
- Last purchase price = `Item Price` from the most recent `Purchase Order Date` per item.
- Inventory cost and available stock come from `Items.csv` (heuristics try `Cost|Rate|Average Cost` and `Available_Stock|AvailableQuantity`).
- Multi-currency note: POs include `Currency Code` and `Exchange Rate` (e.g., 550 CRC/USD), but current UI reports prices as-is (USD). Extend if CRC views are needed.

## Developer workflows
- Local preview: run a static server from repo root and open `/webclient/`. Example: `python -m http.server 8080`.
- Deploy (Zoho Catalyst):
	- Framework: Static; Root Path: `./webclient`; enable Auto Deploy (hot deploy).
	- Put CSVs under `webclient/data/` in the repo. Data path is fixed; no UI toggle.
- Data updates: commit new `SalesHistory_Updated_<MonYYYY>.csv` to `webclient/data/`; the app auto-detects the current month filename (falls back to `SalesHistory_Updated_Oct2025.csv`).
- Export: UI button generates a CSV snapshot of the rendered table.

## Patterns and examples
- Sales CSV example row (from `SalesHistory_Updated_Oct2025.csv`):
	`Item_ID=4198696000033386815, Month_Year=2025-10, Total_Quantity=1.00, Item_SKU=800-4534`.
- PO CSV example row (from `Purchase_Order.csv`):
	`Purchase Order Date=2023-03-01, Item Price=1.13, Product ID=4198696000000141346, SKU=118-119, QuantityOrdered=40, QuantityReceived=40`.

## Guardrails
- Files are large; keep browser parsing efficient and avoid unnecessary DOM work (batch render innerHTML, as in `app.js`).
- Be tolerant of missing `Items.csv`; render with zeros for stock/cost when absent.
- Treat missing or malformed dates as null; only use rows with parseable `YYYY-MM` for monthly bucketing.
- Don’t introduce backend code; keep all logic client-side or optional offline transforms.
- Optional passcode gate in `webclient/assets/pass-config.js` is client-only and not real security; avoid relying on it for sensitive data.

## When extending
- Add calculated columns by enriching `baseItem()` and the render loop.
- For currency conversions, derive CRC via `Exchange Rate` and expose a UI toggle.
- If adding libraries, prefer CDN-delivered, ESM-friendly, and Catalyst-compatible assets.