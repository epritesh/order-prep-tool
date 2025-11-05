# Deployed data folder

When deploying to Zoho Catalyst (Static, Root Path `./webclient`), the site root is the `webclient/` folder. To make CSVs publicly accessible, place them under `webclient/data/` and select "data/ (relative to webclient)" in the UI toggle.

Required files:

- `SalesHistory_Updated_<MonYYYY>.csv`
- `Purchase_Order.csv`
- `Items.csv`

The app will request files at `data/<filename>` relative to `webclient/` when you select the relative option.
