(async function() {
  // Try to use Sigma client SDK if available; otherwise fall back to fetch.
  const orgIdKey = 'org_id';

  async function getOrgId() {
    // If your scaffold exposes an SDK context, prefer that instead of prompt
    try {
      if (window.app && app.context && typeof app.context.get === 'function') {
        const ctx = await app.context.get();
        if (ctx && ctx.organization && ctx.organization.id) return ctx.organization.id;
      }
    } catch {}
    let v = localStorage.getItem(orgIdKey);
    if (!v) {
      v = prompt('Enter your Zoho Books organization_id');
      if (v) localStorage.setItem(orgIdKey, v);
    }
    return v;
  }

  async function callFunction(sku, orgId) {
    // Preferred: Sigma client SDK (instance name may vary)
    if (window.app && app.functions && typeof app.functions.invoke === 'function') {
      return await app.functions.invoke('get_item_snapshot_by_sku', { sku, org_id: orgId });
    }
    // Fallback route (adjust path based on your scaffold)
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
