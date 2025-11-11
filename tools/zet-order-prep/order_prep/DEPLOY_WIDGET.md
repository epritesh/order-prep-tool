# Order Prep Widget Deployment Guide

This guide shows two ways to deploy the Zoho Books widget located in `tools/zet-order-prep/order_prep`.

Contents packaged:
- `plugin-manifest.json`
- `app/` (widget.html, js, img, translations, mock)
- `functions/` (Deluge functions including `get_item_snapshot_by_sku.deluge`)

---
## 1. Manual Upload (Recommended for first deploy)

1. Zip the folder contents:
   - Root for zipping: `tools/zet-order-prep/order_prep` (the files and subfolders inside it, not the parent folder).
   - The resulting zip must have `plugin-manifest.json` at its root.
2. Go to Zoho Books: Settings → Developer Space → Extensions → Upload Extension.
3. Choose your zip file and upload.
4. After upload, open the extension configuration:
   - Functions: Edit `get_item_snapshot_by_sku` and add arguments:
     - `sku` (String)
     - `org_id` (String)
   - Bind connection: `booksconnection`.
5. Authorize connection scopes (if not already):
   - `ZohoBooks.custommodules.READ`
   - `ZohoBooks.items.READ`
   - `ZohoBooks.purchaseorders.READ`
6. Install extension into the organization.
7. Open the custom tab ("Order Prep") and test a known SKU.

### Mapping API route for the widget
The widget code calls a function endpoint using POST to one of these paths:
```
/order-prep/get_item_snapshot_by_sku
/api/get_item_snapshot_by_sku
/functions/get_item_snapshot_by_sku
/extensions/functions/get_item_snapshot_by_sku
```
In the Books Extension UI, define an API Configuration that maps one of those paths to the `get_item_snapshot_by_sku` function. Use the POST method.

If you prefer GET, ensure the configuration allows query params and the function reads arguments accordingly.

---
## 2. Automated Packaging (PowerShell Script)
A helper script `build-widget.ps1` can zip the widget with a timestamp.

Usage (from repo root PowerShell):
```pwsh
cd tools/zet-order-prep/order_prep
pwsh ./build-widget.ps1
```
Optional version override:
```pwsh
pwsh ./build-widget.ps1 -Version 1.0.0
```
Upload the generated zip as in step 2 above.

---
## 3. Post-Deploy Validation Checklist
- Tab loads without console errors
- Enter a valid SKU → item name, KPIs, sales table render
- Enter an invalid SKU → graceful "SKU not found" message
- Outstanding PO Qty updates for recent purchase orders
- Last Purchase shows correct vendor & date
- Sales months contain up to 24 descending labels

---
## 4. Troubleshooting
| Symptom | Likely Cause | Fix |
|--------|--------------|-----|
| "missing sku or org_id" | Function arguments not configured | Add `sku`, `org_id` arguments in Function UI |
| Authorization error (code 57) | Missing scope / stale connection | Re-authorize `booksconnection` with required scopes |
| 0 rows in sales | Custom module not populated or wrong field names | Verify `cf_sku`, `cf_month_year`, `cf_total_quantity` exist |
| Outstanding PO always 0 | PO scan not finding SKU in line items | Confirm SKU field in PO line items matches casing and format |
| Widget fetch fails (404) | API Configuration route not mapped | Map one widget route to the function in API Configurations |
| Slow load >15s | Large PO pages or network | Reduce PO pages (cap already at 6); confirm network latency |

---
## 5. Next Enhancements (Optional)
- Add Net Sales per month to snapshot (extend function to retrieve `cf_net_sales`)
- Add multi-currency conversion support (pass currency_code + exchange rates)
- Add SKU autocomplete (call Items API with search_text while typing)
- Add link button to open Zoho Analytics dashboard with the SKU parameter
- Implement caching (map last snapshot per SKU to reduce PO scans for repeated lookups)

---
## 6. Repack Without Functions (Optional)
If you later move the function server-side or use API Config only:
- Remove `functions/` from the zip
- Keep `plugin-manifest.json` and `app/` only

---
## 7. Clean Unused Assets
Before production, remove:
- `mock/` if no longer needed
- Placeholder logos not used

---
## 8. Versioning Tips
- Add a simple CHANGELOG.md noting zip names and changes
- Tag git commits with `widget-vX.Y.Z`

---
## 9. Security Notes
- All logic client-side except Deluge function calls
- No secrets baked into widget
- Connection scopes limited to read operations

---
## 10. Support Script Recap
See `build-widget.ps1` for repeatable packaging. Integrate into CI to auto-build zip on tagged commits.

---
Happy deploying!
