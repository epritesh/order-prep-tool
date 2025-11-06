# Zoho Books Extension: Order Prep Widget (Live SKU Lookup)

This guide walks you through creating a Zoho Books extension with a custom tab (widget) that takes an exact SKU and shows live results: item info, stock, cost, inventory value, outstanding POs, last purchase, and 24-month sales. It mirrors the logic of this repo’s webclient but uses Zoho Books APIs.

Use this as a copy-paste checklist. You can complete the whole setup in a sandbox org first, then move it to production.

## What you’ll build

- A Custom Tab (widget) inside Zoho Books
- A secure server-side Deluge function calling Zoho Books via an OAuth Connection
- A simple widget UI: 1 SKU input → live data fetch → render KPIs + monthly sales

Data mapping aligns with your DATA_SCHEMA.json (Items, Invoices, Purchase Orders).

---

## Prerequisites

- Zoho Developer access (<https://developer.zoho.com/>)
- Zoho Books sandbox org (recommended for testing)
- Permissions to create Extensions and Connections

Notes on data centers (DC):

- US: zohoapis.com
- EU: zohoapis.eu
- IN: zohoapis.in
- AU: zohoapis.com.au
- JP: zohoapis.jp

Replace the domain in API URLs accordingly if you are not in the US DC.

---

## Step 1 — Create the Books extension (Sigma)

1) In Zoho Developer, open Sigma and click “Start building”.
2) Create New Project → choose “Marketplace Extension”.
3) Product family: Finance → Product: Zoho Books.
4) Name it (e.g., “Order Prep Widget”) and create the project.
5) Install to your sandbox org when prompted (you can publish to production later).

In the Sigma project, the left navigation groups everything you need under Components:

- Widgets (for the Custom Tab UI)
- Functions (Deluge server code)
- Connections (OAuth to Zoho Books)

You’ll add one of each next.

---

## Step 2 — Create an OAuth Connection to Zoho Books (Sigma → Connections)

You’ll call Books APIs from a Deluge function using a Connection.

- Create a Connection inside the extension:
  - Name (exact): `books_conn`
  - Service: Zoho Books
  - Scopes (adjust to your org’s needs; these cover read use-cases here):
    - `ZohoBooks.items.READ`
    - `ZohoBooks.invoices.READ`
    - `ZohoBooks.purchaseorders.READ`
    - `ZohoBooks.settings.READ` (optional, useful for org details)
  - Authorize the connection for your sandbox org.

You’ll reference this connection name in the Deluge code below.

---

## Step 3 — Add a Custom Tab (Widget) in Sigma

In Sigma, go to Components → Widgets and add a widget for Zoho Books (Custom Tab). Point it at the static files you bundle in the extension:

- Files you’ll add to the extension package:
  - `widget/index.html`
  - `widget/app.js`
  - `widget/style.css` (optional)

Configure the widget to serve `widget/index.html`.

---

## Step 4 — Server function (Deluge): get_item_snapshot_by_sku

Create a Deluge function named `get_item_snapshot_by_sku`. It:

- Looks up the item by exact SKU
- Aggregates invoice line quantities by month for the last 24 full months (excluding current month)
- Sums outstanding PO quantity for open-ish statuses (excludes billed/closed/cancelled)
- Tracks last purchase price/vendor by latest PO date
- Returns a compact JSON payload the widget renders

Parameters: `sku` (string), `org_id` (string)

Connection: `books_conn`

Paste this Deluge code (adjust domain for your DC if needed):

```deluge
// Helper: format YYYY-MM for a Deluge date
to_month_key = function(d)
{
    year = d.getYear().toString();
    month = d.getMonth().toString(); // 01..12
    return year + "-" + month;
};

// Helper: compute last 24 months excluding current month
month_window_24 = function()
{
    now = zoho.currentdate;
    first_this = date.toDate(now.getYear() + "-" + now.getMonth() + "-01");
    last_prev = first_this.addDay(-1);
    months = List();
    d = last_prev;
    for each i in 1..24
    {
        months.add(to_month_key(d));
        first = date.toDate(d.getYear() + "-" + d.getMonth() + "-01");
        d = first.addDay(-1);
    }
    return months; // newest first
};

responseMap = Map();
try
{
    sku = input.sku.trim();
    org_id = input.org_id;
    if(sku.isEmpty() || org_id.isEmpty())
    {
        return {"error":"Missing sku or org_id"};
    }

    // 1) Items: GET /items?search_text=... then filter exact SKU
    items_url = "https://www.zohoapis.com/books/v3/items";
    items_params = {"organization_id":org_id,"search_text":sku,"page":"1","per_page":"200"};
    items_resp = invokeurl
    [
        url : items_url
        type : GET
        parameters: items_params
        connection : "books_conn"
    ];
    if(items_resp.get("code") != 0)
    {
        return {"error":"Items API error","details":items_resp};
    }
    item_list = items_resp.get("items");
    target_item = null;
    for each it in item_list
    {
        if(it.get("sku") == sku)
        {
            target_item = it;
            break;
        }
    }
    if(target_item == null)
    {
        return {"error":"No item found for exact SKU","sku":sku};
    }

    item_id = target_item.get("item_id").toString();
    item_name = target_item.get("name");
    available = ifnull(target_item.get("stock_on_hand"),0);
    cost = ifnull(target_item.get("purchase_details") != null ? target_item.get("purchase_details").get("rate") : null, 0);
    supplier_code = "";
    if(target_item.containsKey("custom_fields"))
    {
        for each cf in target_item.get("custom_fields")
        {
            if(cf.get("label") == "Supplier Code" || cf.get("label") == "CF.Supplier Code")
            {
                supplier_code = ifnull(cf.get("value"),"");
            }
        }
    }

    // 2) Sales: GET /invoices with date range over last 24 months, aggregate qty by month for this item_id
    months = month_window_24(); // newest-first keys
    sales_by_month = Map();
    for each mkey in months
    {
        sales_by_month.put(mkey,0.0);
    }
    oldest = months.get(months.size() - 1);
    newest = months.get(0);
    from_date = oldest + "-01";
    to_date = newest + "-31";

    inv_url = "https://www.zohoapis.com/books/v3/invoices";
    inv_page = 1;
    while(true)
    {
        inv_params = {
            "organization_id":org_id,
            "filter_by":"Date.Range",
            "from_date":from_date,
            "to_date":to_date,
            "page":inv_page.toString(),
            "per_page":"200"
        };
        inv_resp = invokeurl
        [
            url : inv_url
            type : GET
            parameters: inv_params
            connection : "books_conn"
        ];
        if(inv_resp.get("code") != 0)
        {
            break;
        }
        invoices = inv_resp.get("invoices");
        if(invoices.isEmpty())
        {
            break;
        }
        for each inv in invoices
        {
            lines = inv.get("line_items");
            if(lines == null)
            {
                continue;
            }
            inv_date = inv.get("date"); // yyyy-mm-dd
            mkey = (inv_date != null && inv_date.length() >= 7) ? inv_date.substring(0,7) : null;
            for each li in lines
            {
                if(li.get("item_id").toString() == item_id)
                {
                    q = ifnull(li.get("quantity"),0.0);
                    if(mkey != null && sales_by_month.containsKey(mkey))
                    {
                        sales_by_month.put(mkey, sales_by_month.get(mkey) + q);
                    }
                }
            }
        }
        page_context = inv_resp.get("page_context");
        if(page_context == null || page_context.get("has_more_page") == false)
        {
            break;
        }
        inv_page = inv_page + 1;
    }

    // 3) Purchase Orders: exclude billed/closed/cancelled
    po_url = "https://www.zohoapis.com/books/v3/purchaseorders";
    po_page = 1;
    outstanding = 0.0;
    last_purchase = Map();
    last_purchase.put("price",null);
    last_purchase.put("vendor_name",null);
    last_purchase.put("date",null);
    last_date = null;

    while(true)
    {
        po_params = {
            "organization_id":org_id,
            "page":po_page.toString(),
            "per_page":"200"
        };
        po_resp = invokeurl
        [
            url : po_url
            type : GET
            parameters: po_params
            connection : "books_conn"
        ];
        if(po_resp.get("code") != 0)
        {
            break;
        }
        pos = po_resp.get("purchaseorders");
        if(pos.isEmpty())
        {
            break;
        }
        for each po in pos
        {
            status = po.get("status");
            if(status != null)
            {
                lower = status.toLowerCase();
                if(lower.contains("billed") || lower.contains("closed") || lower.contains("cancelled"))
                {
                    continue;
                }
            }
            po_date = po.get("date");
            vendor = po.get("vendor_name");
            lines = po.get("line_items");
            if(lines == null)
            {
                continue;
            }
            for each li in lines
            {
                if(li.get("item_id").toString() == item_id)
                {
                    qo = ifnull(li.get("quantity_ordered"),0.0);
                    qr = ifnull(li.get("quantity_received"),0.0);
                    rem = qo - qr;
                    if(rem > 0)
                    {
                        outstanding = outstanding + rem;
                    }
                    price = ifnull(li.get("rate"),null);
                    if(po_date != null && price != null)
                    {
                        if(last_date == null || po_date > last_date)
                        {
                            last_date = po_date;
                            last_purchase.put("price",price);
                            last_purchase.put("vendor_name",vendor);
                            last_purchase.put("date",po_date);
                        }
                    }
                }
            }
        }
        page_context = po_resp.get("page_context");
        if(page_context == null || page_context.get("has_more_page") == false)
        {
            break;
        }
        po_page = po_page + 1;
    }

    responseMap.put("item",{
        "item_id":item_id,
        "item_name":item_name,
        "sku":sku,
        "supplier_code":supplier_code,
        "available":available,
        "cost":cost
    });
    responseMap.put("inventory_value", (available != null && cost != null) ? (available * cost) : 0.0);
    responseMap.put("sales_by_month",sales_by_month);
    responseMap.put("outstanding_po_qty",outstanding);
    responseMap.put("last_purchase",last_purchase);
    return responseMap;
}
catch(e)
{
    return {"error":"Exception","message":e.toString()};
}
```

Tips

- If your org is very large, consider adding a date filter to POs similar to invoices to reduce pages.
- If `stock_on_hand` is unavailable (inventory off), fall back to opening_stock or 0.


---

## Step 5 — Expose the function to the widget (Sigma Client SDK)

In Sigma projects, invoke server functions from your widget via the Sigma client SDK that your scaffold exposes (the object is often provided as `app`, but may differ by template). Example:

```javascript
// Example using the Sigma client SDK inside a widget
const data = await app.functions.invoke('get_item_snapshot_by_sku', { sku, org_id });
```

If your scaffold doesn’t expose `app.functions.invoke`, check the generated docs for the exact SDK import/instance name. As a fallback, you can call the Function URL shown on the Functions page (the platform handles auth when using the SDK; raw fetch may require the embedded context headers).

Payload (JSON):

```json
{ "sku": "509-2003", "org_id": "XXXXXXXX" }
```

---

## Step 6 — Widget UI files

Create these files in your extension package under `widget/`.

`widget/index.html`:

```html
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Order Prep (Live)</title>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <style>
    body{font-family:system-ui,Segoe UI,Arial,sans-serif;margin:16px;}
    .row{display:flex;gap:8px;align-items:center;flex-wrap:wrap}
    input[type=text]{padding:8px 10px;font-size:14px;min-width:220px}
    button{padding:8px 12px;font-size:14px;cursor:pointer}
    .kpis{display:flex;gap:12px;margin-top:12px;flex-wrap:wrap}
    .kpi{border:1px solid #ddd;border-radius:8px;padding:12px 14px;min-width:160px}
    .muted{color:#666;font-size:12px}
    table{border-collapse:collapse;margin-top:12px}
    th,td{border:1px solid #ddd;padding:6px 8px;text-align:right}
    th:first-child,td:first-child{text-align:left}
  </style>
</head>
<body>
  <div class="row">
    <label for="sku">Exact SKU</label>
    <input id="sku" type="text" placeholder="e.g. 509-2003">
    <button id="go">Search</button>
    <span id="status" class="muted"></span>
  </div>

  <div id="result" style="display:none">
    <h3 id="title"></h3>
    <div class="kpis">
      <div class="kpi">
        <div>Available</div>
        <div id="kpiAvailable" style="font-weight:600;font-size:18px"></div>
      </div>
      <div class="kpi">
        <div>Unit cost (CRC)</div>
        <div id="kpiCost" style="font-weight:600;font-size:18px"></div>
      </div>
      <div class="kpi">
        <div>Inventory Value (CRC)</div>
        <div id="kpiInventoryValue" style="font-weight:600;font-size:18px"></div>
      </div>
      <div class="kpi">
        <div>Outstanding PO qty</div>
        <div id="kpiOutstanding" style="font-weight:600;font-size:18px"></div>
      </div>
      <div class="kpi">
        <div>Last Purchase (CRC)</div>
        <div id="kpiLastPurchase" style="font-weight:600;font-size:18px"></div>
        <div id="kpiLastVendor" class="muted"></div>
      </div>
    </div>

    <h4>Sales (last 24 months, newest → oldest)</h4>
    <table id="sales">
      <thead><tr id="salesHead"></tr></thead>
      <tbody><tr id="salesRow"></tr></tbody>
    </table>
  </div>

  <script src="app.js"></script>
</body>
</html>
```

`widget/app.js`:

```javascript
(async function() {
  const orgIdKey = 'org_id';
  async function getOrgId() {
    let v = localStorage.getItem(orgIdKey);
    if (!v) {
      v = prompt('Enter your Zoho Books organization_id');
      if (v) localStorage.setItem(orgIdKey, v);
    }
    return v;
  }

  async function callFunction(sku, orgId) {
    // Preferred: Sigma client SDK (instance name may vary in your scaffold)
    if (window.app && app.functions && typeof app.functions.invoke === 'function') {
      return await app.functions.invoke('get_item_snapshot_by_sku', { sku, org_id: orgId });
    }
    // Fallback: function route (adjust path to your scaffold's generated route)
    const url = '/functions/get_item_snapshot_by_sku';
    const resp = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sku, org_id: orgId })
    });
    if (!resp.ok) {
      const txt = await resp.text();
      throw new Error('Function call failed: ' + txt);
    }
    return resp.json();
  }

  function fmt(n) {
    if (n === null || n === undefined || isNaN(n)) return '-';
    return Number(n).toLocaleString('en-US', { maximumFractionDigits: 2 });
  }

  function render(res) {
    const result = document.getElementById('result');
    const status = document.getElementById('status');
    result.style.display = 'none';
    if (res.error) {
      status.textContent = res.error;
      return;
    }
    const item = res.item || {};
    document.getElementById('title').textContent =
      `${item.item_name || ''} — ${item.sku || ''} ${item.supplier_code ? `(${item.supplier_code})` : ''}`;

    document.getElementById('kpiAvailable').textContent = fmt(item.available);
    document.getElementById('kpiCost').textContent = fmt(item.cost);
    document.getElementById('kpiInventoryValue').textContent = fmt(res.inventory_value || 0);
    document.getElementById('kpiOutstanding').textContent = fmt(res.outstanding_po_qty || 0);

    const lp = res.last_purchase || {};
    document.getElementById('kpiLastPurchase').textContent = lp.price != null ? fmt(lp.price) : '-';
    document.getElementById('kpiLastVendor').textContent = lp.vendor_name ? `${lp.vendor_name} • ${lp.date || ''}` : '';

    const sales = res.sales_by_month || {};
    const keys = Object.keys(sales).sort().reverse(); // newest first
    const head = document.getElementById('salesHead');
    const row = document.getElementById('salesRow');
    head.innerHTML = '<th>Month</th>' + keys.map(k => `<th>${k}</th>`).join('');
    row.innerHTML = '<td>Qty</td>' + keys.map(k => `<td>${fmt(sales[k])}</td>`).join('');

    result.style.display = 'block';
    status.textContent = '';
  }

  document.getElementById('go').addEventListener('click', async () => {
    const sku = document.getElementById('sku').value.trim();
    const status = document.getElementById('status');
    if (!sku) {
      status.textContent = 'Enter an exact SKU';
      return;
    }
    status.textContent = 'Loading...';
    try {
      const orgId = await getOrgId();
      const data = await callFunction(sku, orgId);
      render(data);
    } catch (e) {
      status.textContent = e.message || String(e);
    }
  });
})();
```

---

## Step 7 — Field mapping to your DATA_SCHEMA

- Items (Item.csv → Books Items API)
  - Item ID → `item_id`
  - Item Name → `name`
  - SKU → `sku`
  - Stock On Hand → `stock_on_hand` (inventory tracking must be enabled)
  - Purchase Rate → `purchase_details.rate`
  - Supplier Code (custom) → `custom_fields[label="Supplier Code" or "CF.Supplier Code"].value`

- Purchase Orders (Purchase_Order.csv → Books POs API)
  - Purchase Order Date → `date`
  - Purchase Order Status → `status`
  - Item Price → `line_items.rate`
  - Product ID → `line_items.item_id`
  - QuantityOrdered → `line_items.quantity_ordered`
  - QuantityReceived → `line_items.quantity_received`
  - Outstanding logic → `max(0, ordered − received)` summed across open POs

- Invoices (Invoice/*.csv → Books Invoices API)
  - Invoice Date → `date`
  - Product ID → `line_items.item_id`
  - Quantity → `line_items.quantity`
  - Item Price → `line_items.rate`
  - 24-month window excludes current month

---

## Step 8 — Test in sandbox

1) Install the extension to your sandbox org and open the “Order Prep” tab.
2) Enter a known exact SKU (e.g., `509-2003`).
3) Verify:
   - Available (stock_on_hand) and Unit cost (purchase rate)
   - Inventory Value = Available × Cost
   - Outstanding PO qty excludes billed/closed/cancelled lines
   - Last Purchase shows price/vendor/date from the most recent PO line for that item
   - Sales table shows up to 24 months with the newest month on the left and the current month excluded

If you get “No item found for exact SKU”, confirm the SKU exists and matches exactly. `search_text` returns partial matches; the function filters for exact equality.

---

## Step 9 — Move to production

- Re-authorize the Connection (`books_conn`) against your production org with the same scopes.
- Bump extension version, submit, and publish.
- Add the tab to roles/visibility as needed.

---

## Troubleshooting

- 401/Permission errors: Re-check connection scopes and authorization.
- Function not found: Verify the function name and the invocation path for your extension template.
- Pagination gaps: For large datasets, ensure `page_context.has_more_page` loops until false; consider date filters for POs.
- Missing inventory: If `stock_on_hand` is undefined, ensure inventory tracking is enabled, or fall back to `opening_stock` (with caution).
- Mixed currencies: The widget displays CRC as-is. Normalize if you need multi-currency consistency using `currency_code` and `exchange_rate`.

---

## Optional enhancements

- Caching: Store results by SKU with a short TTL to reduce API calls.
- Faster sales: Precompute monthly aggregates nightly and serve from a small table.
- Creator/Catalyst alternatives: You can host the backend in Zoho Creator or Zoho Catalyst instead, keeping the same response shape.
- UI polish: Add Enter-key submit, CSV export, sparkline, dark mode.

---

## Minimal contract (server ↔ widget)

Request

```json
{ "sku": "<exact-sku>", "org_id": "<books-organization-id>" }
```

Response

```json
{
  "item": {
    "item_id": "...",
    "item_name": "...",
    "sku": "...",
    "supplier_code": "...",
    "available": 0,
    "cost": 0
  },
  "inventory_value": 0,
  "sales_by_month": { "YYYY-MM": 0 },
  "outstanding_po_qty": 0,
  "last_purchase": { "price": 0, "vendor_name": "...", "date": "YYYY-MM-DD" }
}
```

That’s it—once your extension has the tab, connection, function, and widget files above, you’ll have a live, single-SKU Order Prep view inside Zoho Books.
