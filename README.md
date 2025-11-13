# Pantera Order Preparation Tool

Static webclient for analyzing sales, purchase orders, and inventory to prepare orders.

## What it does

- Loads CSVs directly in the browser (no server):
  - `SalesHistory_Updated_<MonYYYY>.csv`
  - `Purchase_Order.csv`
  - `Items.csv`
- Computes per-item:
  - 24 months sales by month (from current month back)
  - Outstanding POs (Ordered − Received)
  - Current available stock (from Items.csv)
  - Last purchase price (latest PO line)
  - System inventory cost (from Items.csv)
  - KPI cards (last purchase price/date/vendor, inventory cost, stock & outstanding) and a compact 24‑month sparkline
- Renders a spreadsheet-like table and allows CSV export.

## Project layout

- `webclient/index.html` — entry point
- `webclient/assets/app.js` — data loading, aggregation, rendering
- `webclient/assets/style.css` — minimal styling
- `data/` — preferred place for CSVs (falls back to project root)

## Local preview

Open `webclient/index.html` in a browser. For best results use a local static server (to avoid CORS for file://):

- VS Code extension: Live Server
- Or Python 3:

```pwsh
# from repo root
python -m http.server 8080
# then open http://localhost:8080/webclient/
```

## Deploy to Zoho Catalyst

- Create a Slate deployment from your GitHub repo
  - Deployment Source: Repository, Branch: `main`
  - Framework: `Static`
  - Root Path: `./webclient`
  - Toggle Auto Deploy: `On` (hot deploy on push)
- Place CSVs inside `webclient/data/` in your repo (so they are included in the deploy). The app loads files from `data/` (relative to `webclient/`).
- No server functions required

## Data expectations

- CSVs must be UTF-8 encoded; dates in `YYYY-MM` or `YYYY-MM-DD`
- Join keys: the app groups by a composite key of `SKU` and `Item_ID`/`Product ID` when present; otherwise falls back to item name.
- Purchase orders: outstanding quantity is `QuantityOrdered − QuantityReceived` (min 0), excluding rows with status `Billed` or `Closed`.

## Notes

- Large CSVs (18k–21k rows) are supported in-browser via PapaParse; initial load can take a few seconds.
- You can add more columns to Items.csv; the app uses heuristics to find `Available_Stock` and `Cost`.
- Click a row (or use the pager with "Show current only") to update the KPI cards and sparkline for the current item.

### Data freshness indicator

The header shows a stamp like:

```
Data current through 2025-11 (partial month) • Loaded 2025-11-08 14:32:10
```

- "Data current through" reflects the most recent month (from the last 24) with non‑zero sales.
- If the current month is included and supplemented by invoice rows (e.g. `Invoices_nov_to_date.csv` / `Invoice_Items.csv`), the stamp appends `(partial month)`.
- Load time is the client load timestamp (browser local time).
- The app now includes the current month in the 24‑month window to surface in‑progress sales.

Supplemental invoices are merged into the current month as additional sales rows (quantity + net sales heuristic). If no invoice supplement exists the current month may still appear with zeroes; the indicator will then fall back to the most recent populated prior month.

## Optional passcode gate (client-only)

For a lightweight barrier (not secure), the app can prompt for a passcode before loading data.

- Configure in `webclient/assets/pass-config.js`:
  - Set `window.PANTERA_PASSCODE = '<your pass>'`.
  - Leave empty (`''`) to disable the prompt.
- The passcode check runs client-side and can be bypassed by anyone who views source. Use platform-level auth if you need real protection.
