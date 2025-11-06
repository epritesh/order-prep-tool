# Order Prep Widget — Dev Workflow

This doc shows how to run the widget locally, iterate quickly with mock data, and deploy via the ZET CLI.

## Prereqs

- Node.js LTS installed
- ZET CLI installed globally: `npm i -g @zohoextensiontoolkit/zet`
- First run only: trust the self-signed cert when the local server starts (open the printed <https://127.0.0.1:PORT> once and click Advanced → Proceed).

## Local develop with mock data

Run from this folder (`tools/zet-order-prep/order_prep`):

```pwsh
# Start local HTTPS dev server (serves /app)
npm run dev
# If you prefer, you can also use the vanilla server:
npm start
```

Open:

- <https://127.0.0.1:5000/app> (or the next available port up to 5009)

Notes:

- When running on 127.0.0.1/localhost, the UI auto-loads `app/mock/get_item_snapshot_by_sku.json` so you can iterate on rendering without a backend.
- Enter any SKU (e.g., `SAMPLE-001`) and click Go to see the mocked KPIs and 12 months of sales.
- If `ZFAPPS` SDK isn’t available locally, you’ll be prompted once for `organization_id` (saved to localStorage).

## Deploy from CLI (no manual ZIP upload)

Authenticate and pick your Sigma workspace (one-time per session):

```pwsh
zet login          # Opens browser; sign in to your Sigma account
zet list_workspace # Choose the target workspace (if prompted)
zet whoami         # Verify account and workspace
```

Push the current project to Sigma:

```pwsh
npm run pack  # optional; validates and creates dist/order_prep.zip
npm run push  # pushes the extension to Sigma in the selected workspace
```

Optionally, run in Sigma without publishing:

```pwsh
zet cloud_run   # start a temp dev session in Sigma
zet cloud_stop  # stop the session
```

Tips:

- Configure your Books widget API route in Developer Portal to `/order-prep/get_item_snapshot_by_sku` to match the widget’s preferred path.
- If you change the route, the widget will try other fallbacks, or you can hard-wire the exact path in `app/js/extension.js`.
