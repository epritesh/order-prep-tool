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
