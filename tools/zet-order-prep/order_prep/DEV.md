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

## Books Workflow custom function: Lookup sales by SKU

If you prefer a native Books workflow (no external calls), use the custom function in `functions/workflow_lookup_sales_by_sku.deluge`.

Wiring steps (Zoho Books):

1. Settings → Automation → Custom Functions → New Function.
2. Choose “Use Deluge Script” and set Module = your Custom Module (Item Monthly Sales) or keep it global.
3. Paste the contents of `workflow_lookup_sales_by_sku.deluge`.
4. Ensure you have a connection named `booksconnection` with Books scopes that allow custommodules read.
5. Save. Optionally, create a Workflow Rule or a Custom Button that executes this function.

Notes:

- The function reads three maps (record, organization, user). It expects the current record to have `cf_sku`.
- It queries the `cm_item_monthly_sales` module via Books REST and renders an HTML table of the last 24 months.
- You can override the months window by adding a numeric field `cf_months` (1–36) on the record.

## Admin: Bulk-approve Item Monthly Sales records

To promote existing Draft records to Approved in the `cm_item_monthly_sales` module, use the custom function `functions/admin_bulk_approve_item_monthly_sales.deluge`.

Steps (Zoho Books):

1. Settings → Automation → Custom Functions → New Function (Deluge Script).
2. Paste the contents of `admin_bulk_approve_item_monthly_sales.deluge`.
3. Ensure the `booksconnection` connection exists with proper scopes.
4. Execute the function (manually or via a temporary workflow) to process all draft records in pages of 200.

What it does:

- Detects the proper API endpoint for Books custom modules using `organization.api_root_endpoint`.
- Pages through Draft records and updates each to `status = approved`.
- Logs counts for Updated and Failed.

Safety tips:

- Run during off-hours if you have many records.
- Optionally clone a few records and test before running across all pages.

### Approve just the current record (for bulk buttons)

Use `functions/admin_approve_current_monthly_sales_record.deluge` when you want a button-based action that approves only the record that invoked it. In Books, adding this as a bulk custom button will typically execute the function once per selected record.

Steps:

1. Settings → Automation → Custom Functions → New Function (Deluge Script).
2. Paste `admin_approve_current_monthly_sales_record.deluge`.
3. Attach it as a button to the `cm_item_monthly_sales` module (single or bulk action).
4. Ensure `booksconnection` exists with write scopes for custom modules.

Behavior:

- Resolves `organization.api_root_endpoint` and selects the correct endpoint.
- Reads `module_record_id` from the context record and sets `status = approved`.
- Logs success/failure for that record.
