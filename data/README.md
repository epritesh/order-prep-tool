# Data folder

Place the following CSV files here (or keep them in project root). The webclient prefers `/data/` but will fall back to root:

- `SalesHistory_Updated_<MonYYYY>.csv` (e.g., `SalesHistory_Updated_Oct2025.csv`)
- `Purchase_Order.csv`
- `Items.csv`

## Items.csv expected headers

Minimal recommended columns (case-insensitive; webclient uses heuristics):

- `Item_ID` or `Product ID` (string)
- `Item_Name` (string)
- `SKU` (string)
- `Available_Stock` (number)
- `Cost` (number) — system inventory cost

The app can also infer `Rate`, `Average Cost`, or `Inventory Cost` as cost, and `AvailableQuantity` variants for stock.
