(function(){
	// Try to use Books embedded context via ZF SDK to get org_id
	async function getOrgId() {
		try {
			if (window.ZFAPPS && ZFAPPS.extension && typeof ZFAPPS.extension.init === 'function') {
				const App = await ZFAPPS.extension.init();
				if (App && App.organization && App.organization.id) return App.organization.id;
			}
		} catch(e) {}
		// Fallback prompt (cached)
		const k = 'org_id';
		let v = localStorage.getItem(k);
		if (!v) {
			v = prompt('Enter your Zoho Books organization_id');
			if (v) localStorage.setItem(k, v);
		}
		return v;
	}

		async function callFunction(sku, orgId) {
		// If Sigma/portal exposes a function invoker to the widget, hook it here.
		// Otherwise, use a conventional route that you configure for your Function.
			const tryPaths = [
				// Common Sigma/Books API Configuration routes (configure one of these in Build > Widgets > API Configurations)
				'/order-prep/get_item_snapshot_by_sku',
				'/api/get_item_snapshot_by_sku',
				// Generic fallbacks used by some templates
				'/functions/get_item_snapshot_by_sku',
				'/extensions/functions/get_item_snapshot_by_sku'
			];
			const buildQuery = (base) => `${base}?sku=${encodeURIComponent(sku)}&org_id=${encodeURIComponent(orgId)}`;
		const isLocalDev = ['127.0.0.1', 'localhost'].includes(location.hostname);
		let lastErr;
		// In local dev, try mock data first to enable fast UI iteration
		if (isLocalDev) {
			try {
				const mockUrl = 'mock/get_item_snapshot_by_sku.json';
				const r = await fetch(mockUrl, { cache: 'no-cache' });
				if (r.ok) return r.json();
				lastErr = await r.text();
			} catch(e) { lastErr = e.message || String(e); }
		}
		// Otherwise, try the configured API routes in the host (Sigma/Books)
		for (const url of tryPaths) {
			try {
				const resp = await fetch(url, {
					method: 'POST',
					headers: { 'Content-Type': 'application/json' },
					body: JSON.stringify({ sku, org_id: orgId })
				});
				if (resp.ok) return resp.json();
				lastErr = await resp.text();
			} catch (e) { lastErr = e.message || String(e); }
			// Fallback: try GET with query params for APIs mapped to GET and function arguments
			try {
				const resp2 = await fetch(buildQuery(url), { method: 'GET' });
				if (resp2.ok) return resp2.json();
				lastErr = await resp2.text();
			} catch (e) { lastErr = e.message || String(e); }
		}
		throw new Error(lastErr || 'Function call failed');
	}

	function fmt(n) {
		if (n === null || n === undefined || isNaN(n)) return '-';
		return Number(n).toLocaleString('en-US', { maximumFractionDigits: 2 });
	}

	function render(res) {
		const result = document.getElementById('result');
		const status = document.getElementById('status');
		result.style.display = 'none';
		if (!res || res.error) {
			status.textContent = res && res.error ? res.error : 'No data';
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
		const keys = Object.keys(sales).sort().reverse();
		const head = document.getElementById('salesHead');
		const row = document.getElementById('salesRow');
		head.innerHTML = '<th>Month</th>' + keys.map(k => `<th>${k}</th>`).join('');
		row.innerHTML = '<td>Qty</td>' + keys.map(k => `<td>${fmt(sales[k])}</td>`).join('');

		result.style.display = 'block';
		status.textContent = '';
	}

	document.addEventListener('DOMContentLoaded', function(){
		const btn = document.getElementById('go');
		if (!btn) return;
		btn.addEventListener('click', async () => {
			const sku = document.getElementById('sku').value.trim();
			const status = document.getElementById('status');
			if (!sku) { status.textContent = 'Enter an exact SKU'; return; }
			status.textContent = 'Loading...';
			try {
				const orgId = await getOrgId();
				const data = await callFunction(sku, orgId);
				render(data);
			} catch (e) {
				status.textContent = e.message || String(e);
			}
		});
	});
})();
