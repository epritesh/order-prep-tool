// Pantera Order Preparation - Browser App
// Loads CSV files from /data (or root) and renders a spreadsheet-like table per item

const state = {
  salesRows: [],
  poRows: [],
  itemRows: [],
  months: [], // last 24 months labels like '2025-11'
  byItem: new Map(), // key -> aggregated object
  // Fixed data path for deployed app (files under webclient/data)
  dataBasePath: 'data/',
  // filtering / navigation
  skuFilterSet: null, // Set of SKUs if filtering
  skuFilterPatterns: null, // Array<RegExp> for wildcard filtering
  filteredKeys: [],
  currentIndex: 0,
  showCurrentOnly: false,
  selectedKey: null,
};

const el = {
  status: document.getElementById('status'),
  reloadBtn: document.getElementById('reloadBtn'),
  themeToggle: document.getElementById('themeToggle'),
  head: document.getElementById('grid-head'),
  body: document.getElementById('grid-body'),
  exportCsvBtn: document.getElementById('exportCsvBtn'),
  // SKU filter UI
  skuList: document.getElementById('skuList'),
  applySkusBtn: document.getElementById('applySkusBtn'),
  clearSkusBtn: document.getElementById('clearSkusBtn'),
  showCurrentOnly: document.getElementById('showCurrentOnly'),
  prevBtn: document.getElementById('prevBtn'),
  nextBtn: document.getElementById('nextBtn'),
  pagerLabel: document.getElementById('pagerLabel'),
  exportFilteredBtn: document.getElementById('exportFilteredBtn'),
  exportAllBtn: document.getElementById('exportAllBtn'),
  skuSearch: document.getElementById('skuSearch'),
  lookupBtn: document.getElementById('lookupBtn'),
};

function setStatus(msg) { el.status.textContent = msg; }

function monthKey(d) { return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}`; }

function formatMonthLabel(key){
  const [y,m] = key.split('-');
  const monthNames = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  const idx = Number(m)-1;
  return `${monthNames[idx]} ${y}`;
}

// Build an array of the last 24 month keys. By default we INCLUDE the current
// month so that partial in‑flight sales (e.g. invoices to date) can surface.
// Pass includeCurrent=false to retain legacy behaviour (exclude current month).
function computeLast24Months(includeCurrent = true) {
  const now = new Date();
  const anchor = includeCurrent
    ? new Date(now.getFullYear(), now.getMonth(), 1)
    : new Date(now.getFullYear(), now.getMonth() - 1, 1);
  const months = [];
  for (let i = 23; i >= 0; i--) {
    const d = new Date(anchor.getFullYear(), anchor.getMonth() - i, 1);
    months.push(monthKey(d));
  }
  state.months = months;
}

async function fetchTextMaybe(paths) {
  for (const p of paths) {
    try {
      const res = await fetch(p);
      if (res.ok) return await res.text();
    } catch {}
  }
  return null;
}

async function loadCsv(filename) {
  const base = state.dataBasePath;
  // Fixed path; still try root as a dev fallback
  const txt = await fetchTextMaybe([`${base}${filename}`, `/${filename}`]);
  if (!txt) return [];
  return new Promise((resolve) => {
    Papa.parse(txt, {
      header: true,
      skipEmptyLines: true,
      transformHeader: (h) => h.trim(),
      complete: (res) => resolve(res.data)
    });
  });
}

// Heuristic accessors across bilingual/variant headers
const H = {
  itemId: (r) => r['Item_ID'] || r['Product ID'] || r['Item Id'] || r['ProductID'] || r['Item ID'],
  sku: (r) => r['Item_SKU'] || r['SKU'] || r['Item SKU'],
  itemName: (r) => r['Item_Name'] || r['Item Name'] || r['Item Desc'] || r['Item Description'] || r['Item Desc.'],
  supplierCode: (r) => r['CF_Supplier_Code'] || r['Item.CF.Supplier Code'] || r['Supplier Code'],
  month: (r) => r['Month_Year'] || r['Month-Year'] || r['MonthYear'],
  totalQty: (r) => num(r['Total_Quantity'] || r['Quantity'] || r['Qty'] || r['Total Qty']),
  netSales: (r) => num(r['Net_Sales'] || r['Net Sales'] || r['Sales']),
  // Purchase orders
  poDate: (r) => r['Purchase Order Date'] || r['Date'] || r['PO Date'],
  poStatus: (r) => r['Purchase Order Status'] || r['Status'],
  poItemPrice: (r) => num(r['Item Price'] || r['Rate'] || r['Unit Price']),
  poQtyOrdered: (r) => num(r['QuantityOrdered'] || r['Qty Ordered'] || r['Quantity Ordered']),
  poQtyReceived: (r) => num(r['QuantityReceived'] || r['Qty Received'] || r['Quantity Received']),
  poVendor: (r) => r['Vendor Name'] || r['Vendor'] || r['Supplier'],
  // Items master
  available: (r) => num(
    r['Available_Stock'] || r['Available Stock'] || r['AvailableQuantity'] || r['Available Qty'] || r['Stock Available'] || r['Stock On Hand'] || r['Stock on Hand'] || r['StockOnHand'] || r['Available']
  ),
  cost: (r) => num(
    r['Cost'] || r['Purchase Rate'] || r['Purchase Price'] || r['Average Cost'] || r['Inventory Cost'] || r['Rate']
  ),
};

function num(v) {
  if (v === undefined || v === null || v === '') return 0;
  if (typeof v === 'number') return v;
  // Strip currency codes/symbols (e.g., "CRC", "$"), keep digits, minus and decimal point
  const s = String(v).replace(/[\s,]/g, '').replace(/[^0-9.\-]/g, '');
  const n = Number(s);
  return isFinite(n) ? n : 0;
}

function parseDate(s) {
  if (!s) return null;
  const m = String(s).match(/^(\d{4})-(\d{2})(?:-(\d{2}))?/);
  if (m) {
    return new Date(Number(m[1]), Number(m[2]) - 1, m[3] ? Number(m[3]) : 1);
  }
  const d = new Date(s);
  return isNaN(d) ? null : d;
}
function makeKey(r) {
  const rawSku = H.sku(r);
  const rawId = H.itemId(r);
  const sku = rawSku !== undefined && rawSku !== null ? String(rawSku).trim() : '';
  const id = rawId !== undefined && rawId !== null ? String(rawId).trim() : '';
  if (sku && id) return `${sku}__${id}`;
  if (sku) return sku;
  if (id) return id;
  const nm = H.itemName(r);
  return (nm ? String(nm).trim() : '') || JSON.stringify(r).slice(0,64);
}

function aggregate() {
  state.byItem.clear();

  // Seed from Items for stock/cost
  for (const r of state.itemRows) {
    const key = makeKey(r);
    if (!state.byItem.has(key)) state.byItem.set(key, baseItem(r));
    const o = state.byItem.get(key);
    o.itemId ||= H.itemId(r);
    o.sku ||= H.sku(r);
    o.name ||= H.itemName(r);
    o.supplier ||= H.supplierCode(r);
    o.available = H.available(r) || o.available;
    o.cost = H.cost(r) || o.cost;
  }

  // Sales: last 24 months totals per item
  for (const r of state.salesRows) {
    const key = makeKey(r);
    if (!state.byItem.has(key)) state.byItem.set(key, baseItem(r));
    const o = state.byItem.get(key);
    o.itemId ||= H.itemId(r);
    o.sku ||= H.sku(r);
    o.name ||= H.itemName(r);
    o.supplier ||= H.supplierCode(r);
    const m = H.month(r);
    if (m && state.months.includes(m)) {
      o.salesByMonth[m] = (o.salesByMonth[m] || 0) + H.totalQty(r);
    }
  }

  // Purchase orders: outstanding and last price
  for (const r of state.poRows) {
    const key = makeKey(r);
    if (!state.byItem.has(key)) state.byItem.set(key, baseItem(r));
    const o = state.byItem.get(key);
    const status = String(H.poStatus(r) || '').trim().toLowerCase();
    const isExcluded = status.includes('billed') || status.includes('closed');
    const ordered = H.poQtyOrdered(r);
    const received = H.poQtyReceived(r);
    const outstanding = Math.max(0, ordered - received);
    // Exclude Billed/Closed lines from outstanding PO calculation
    if (!isExcluded && outstanding > 0) o.outstandingQty += outstanding;
    const d = parseDate(H.poDate(r));
    if (d) {
      if (!o._lastPoDate || d > o._lastPoDate) {
        o._lastPoDate = d;
        o.lastPurchasePrice = H.poItemPrice(r);
        o.lastVendor = H.poVendor(r) || o.lastVendor;
        o.supplierName = H.poVendor(r) || o.supplierName;
      }
    }
  }
  // Diagnostics: summarize current month activity
  const currentMonth = monthKey(new Date());
  const activeCount = Array.from(state.byItem.values()).filter(o => (o.salesByMonth[currentMonth] || 0) > 0).length;
  console.log('[Pantera] Aggregate complete. Items:', state.byItem.size, 'with current-month qty >0:', activeCount, 'Month:', currentMonth);
}

function baseItem(r) {
  const obj = {
    itemId: H.itemId(r) || '',
    sku: H.sku(r) || '',
    name: H.itemName(r) || '',
    supplier: H.supplierCode(r) || '',
    supplierName: '',
    available: 0,
    cost: 0,
    lastPurchasePrice: 0,
    outstandingQty: 0,
    salesByMonth: {},
    _lastPoDate: null,
  };
  // init months to 0 for stable columns
  for (const m of state.months) obj.salesByMonth[m] = 0;
  return obj;
}

function render() {
  // Build columns
  const staticCols = [
    { key: 'itemId', label: 'Item ID' },
    { key: 'sku', label: 'SKU' },
    { key: 'name', label: 'Item Name' },
    { key: 'supplier', label: 'Supplier Code' },
    { key: 'supplierName', label: 'Supplier Name' },
    { key: 'available', label: 'Available Stock' },
    { key: 'cost', label: 'Inventory Cost' },
    { key: 'lastPurchasePrice', label: 'Last Purchase Price' },
    { key: 'outstandingQty', label: 'Outstanding PO Qty' },
    { key: 'orderQty', label: 'Order Qty' },
  ];
  // Show most recent month on the left by reversing display order
  const monthsDisplay = [...state.months].reverse();
  const currentMonthKey = monthsDisplay[0];
  const monthCols = monthsDisplay.map((m,i) => ({ key: `m:${m}`, label: i===0 ? `${m} (To Date)` : m }));
  const cols = [...staticCols, ...monthCols];

  // Render header
  el.head.innerHTML = '<tr>' + cols.map(c => `<th>${c.label}</th>`).join('') + '</tr>';

  // Rows
  let entries = Array.from(state.byItem.entries());
  // Apply SKU filter if present
  if (state.skuFilterPatterns && state.skuFilterPatterns.length > 0) {
    entries = entries.filter(([k, v]) => {
      const sku = String(v.sku || '').trim();
      return state.skuFilterPatterns.some(re => re.test(sku));
    });
  } else if (state.skuFilterSet && state.skuFilterSet.size > 0) {
    entries = entries.filter(([k, v]) => v.sku && state.skuFilterSet.has(String(v.sku).trim()));
  }
  state.filteredKeys = entries.map(([k]) => k);

  const rows = entries.map(([, v]) => v);
  // Ensure there's a selected row for KPIs/chart
  if (!state.selectedKey || !state.filteredKeys.includes(state.selectedKey)) {
    state.selectedKey = state.filteredKeys[state.currentIndex] || state.filteredKeys[0] || null;
  }
  const html = [];
  rows.forEach((r, idx) => {
    const cells = [];
    for (const c of staticCols) {
      let v = r[c.key];
      if (c.key === 'orderQty') {
        cells.push(`<td><input type="number" class="order-input" data-key="${escapeHtml(makeKey(r))}" value="${r.orderQty ?? ''}" min="0" step="1"></td>`);
        continue;
      }
      if (c.key === 'currentMonthToDate') {
        const tv = r.salesByMonth[currentMonthKey] || 0;
        cells.push(`<td class="num">${tv ? tv.toLocaleString() : ''}</td>`);
        continue;
      }
      if (typeof v === 'number') v = v.toLocaleString();
      if (c.key === 'name' || c.key === 'supplier' || c.key === 'supplierName') {
        const title = v ?? '';
        cells.push(`<td title="${escapeHtml(title)}">${v ?? ''}</td>`);
      } else {
        cells.push(`<td>${v ?? ''}</td>`);
      }
    }
    // Render sales columns with most recent on the left
    for (const m of monthsDisplay) {
      const v = r.salesByMonth[m] || 0;
      // Always show 0 explicitly for clarity; highlight current month when >0
      const isCurrentMonth = (m === monthsDisplay[0]);
      const cls = `num${isCurrentMonth && v>0 ? ' current-positive' : ''}`;
      cells.push(`<td class="${cls}" data-month="${m}">${(v||0).toLocaleString()}</td>`);
    }
    const k = makeKey(r);
    const isCurrent = (state.showCurrentOnly && state.filteredKeys[state.currentIndex] === k) || (!state.showCurrentOnly && state.selectedKey === k);
    html.push(`<tr data-key="${escapeHtml(k)}" class="${isCurrent ? 'current-row' : ''}">${cells.join('')}</tr>`);
  });

  if (state.showCurrentOnly && state.filteredKeys.length > 0) {
    el.body.innerHTML = html[state.currentIndex] ?? '';
  } else {
    el.body.innerHTML = html.join('');
  }

  // Attach handlers for order inputs
  el.body.querySelectorAll('.order-input').forEach(inp => {
    inp.addEventListener('input', (e) => {
      const key = inp.getAttribute('data-key');
      const row = state.byItem.get(key);
      if (row) {
        row.orderQty = num(inp.value);
        persistOrderQty(key, row.orderQty);
      }
    });
  });

  // Row click selection handled via delegated listener in init()

  // Update pager label
  el.pagerLabel.textContent = `${Math.min(state.currentIndex+1, Math.max(1, state.filteredKeys.length))} of ${state.filteredKeys.length}`;

  // Update summary panel
  renderSummary();
}

// Debug rendering helper: logs aggregated row and month cell values after a render
window.debugRenderSku = function(sku){
  const cm = monthKey(new Date());
  const entry = Array.from(state.byItem.values()).find(o => String(o.sku||'').trim() === String(sku).trim());
  if(!entry){ console.warn('[Pantera][debugRenderSku] No aggregated entry for SKU', sku); return; }
  console.log('[Pantera][debugRenderSku] Aggregated salesByMonth current:', entry.salesByMonth[cm], 'All months:', entry.salesByMonth);
  const rowEl = Array.from(document.querySelectorAll('tr[data-key]')).find(tr => tr.getAttribute('data-key').startsWith(String(sku).trim()+'__'));
  if(!rowEl){ console.warn('[Pantera][debugRenderSku] No row element found for SKU', sku); return; }
  const monthTds = rowEl.querySelectorAll('td[data-month]');
  const map = {}; monthTds.forEach(td => { map[td.getAttribute('data-month')] = td.textContent; });
  console.log('[Pantera][debugRenderSku] Rendered cell texts:', map);
};

function exportCsvAll() {
  const rows = Array.from(state.byItem.values());
  const monthsDisplayAll = [...state.months].reverse();
  const currentMonthKey = monthsDisplayAll[0];
  const monthsDisplay = monthsDisplayAll.filter(m => m !== currentMonthKey);
  const header = ['Item ID','SKU','Item Name','Supplier Code','Available Stock','Inventory Cost','Last Purchase Price','Outstanding PO Qty','Order Qty',`${currentMonthKey} (To Date)`,...monthsDisplay];
  const data = rows.map(r => [
    r.itemId, r.sku, r.name, r.supplier, r.supplierName || r.lastVendor || '', r.available, r.cost, r.lastPurchasePrice, r.outstandingQty, r.orderQty || 0,
    (r.salesByMonth[currentMonthKey]||0), ...monthsDisplay.map(m => r.salesByMonth[m] || 0)
  ]);
  const csv = [header.join(','), ...data.map(row => row.map(safeCsv).join(','))].join('\n');
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `pantera_spreadsheet_${state.months[0]}_to_${state.months[state.months.length-1]}.csv`;
  a.click();
  URL.revokeObjectURL(url);
}

function exportCsvFiltered() {
  // Export only filtered keys and include Order Qty
  const keys = state.filteredKeys.length ? state.filteredKeys : Array.from(state.byItem.keys());
  const monthsDisplayAll = [...state.months].reverse();
  const currentMonthKey = monthsDisplayAll[0];
  const monthsDisplay = monthsDisplayAll.filter(m => m !== currentMonthKey);
  const header = ['Item ID','SKU','Item Name','Supplier Code','Supplier Name','Available Stock','Inventory Cost','Last Purchase Price','Outstanding PO Qty','Order Qty',`${currentMonthKey} (To Date)`,...monthsDisplay];
  const rows = keys.map(k => state.byItem.get(k)).filter(Boolean);
  const data = rows.map(r => [
    r.itemId, r.sku, r.name, r.supplier, r.supplierName || r.lastVendor || '', r.available, r.cost, r.lastPurchasePrice, r.outstandingQty, r.orderQty || 0,
    (r.salesByMonth[currentMonthKey]||0), ...monthsDisplay.map(m => r.salesByMonth[m] || 0)
  ]);
  const csv = [header.join(','), ...data.map(row => row.map(safeCsv).join(','))].join('\n');
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8;' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `pantera_filtered_${state.months[0]}_to_${state.months[state.months.length-1]}.csv`;
  a.click();
  URL.revokeObjectURL(url);
}

function safeCsv(v) {
  if (v === null || v === undefined) return '';
  const s = String(v);
  if (/[",\n]/.test(s)) return '"' + s.replace(/"/g,'""') + '"';
  return s;
}

async function loadAll() {
  setStatus('Loading...');
  // Include current month to allow partial invoice merge
  computeLast24Months(true);

  const salesName = await resolveSalesFilename();
  const [sales, pos] = await Promise.all([
    loadCsv(salesName),
    loadCsv('Purchase_Order.csv'),
  ]);
  // Optional current month supplemental invoices (partial month to date)
  // Try a specific to-date file, then fall back to a generic invoice export.
  const invoiceSupplement = await tryLoadInvoiceSupplement();

  // Items master: allow both "Items.csv" and fallback to "Item.csv"
  let items = await loadCsv('Items.csv');
  if (!items || items.length === 0) {
    items = await loadCsv('Item.csv');
  }
  state.salesRows = sales;
  state.poRows = pos;
  state.itemRows = items;

  // Merge supplemental invoice quantities into the current month bucket
  if (invoiceSupplement?.length) {
    integrateInvoiceSupplement(invoiceSupplement);
  }

  aggregate();
  applyPersistedOrderQtys();
  render();
  updateDataStamp(invoiceSupplement?.length || 0);
  // Clearer status: aggregated vs items master and total with outstanding POs
  const outstandingCount = Array.from(state.byItem.values()).reduce((n, r) => n + ((r.outstandingQty||0) > 0 ? 1 : 0), 0);
  setStatus(`Aggregated items: ${state.byItem.size.toLocaleString()} • Items master: ${items.length.toLocaleString()} • Outstanding POs: ${outstandingCount.toLocaleString()} items`);
}

// Attempt to load a current-month invoice supplement file.
// If both an explicit to-date file and a full export exist, union them to cover
// late additions. Deduplicate by (Invoice ID/Number, Product ID, SKU, Quantity).
async function tryLoadInvoiceSupplement() {
  const primaryNames = [
    'Invoices_nov_to_date.csv', // explicit provided naming pattern
    'Invoices_current_to_date.csv', // generic pattern (future proof)
  ];
  const fallbackName = 'Invoice_Items.csv';
  let primary = [];
  for (const name of primaryNames) {
    const rows = await loadCsv(name);
    if (rows && rows.length) { primary = rows; break; }
  }
  const fallback = await loadCsv(fallbackName);
  if (!primary.length && !fallback.length) return [];

  // If only one exists, return it
  if (primary.length && !fallback.length) return primary;
  if (!primary.length && fallback.length) return fallback;

  // Union with de-duplication
  const seen = new Set();
  const keyOf = (r) => [
    r['Invoice ID'] || r['Invoice Number'] || '',
    r['Product ID'] || r['Item_ID'] || r['Item ID'] || '',
    r['SKU'] || r['Item_SKU'] || '',
    r['Quantity'] || r['Qty'] || r['Total_Quantity'] || ''
  ].map(x => String(x||'').trim()).join('|');
  const out = [];
  const add = (r) => { const k = keyOf(r); if (!seen.has(k)) { seen.add(k); out.push(r); } };
  primary.forEach(add);
  fallback.forEach(add);

  // Diagnostics: log coverage window
  const dates = out.map(r => r['Invoice Date'] || r['Date'] || r['Created Time'] || r['Last Modified Time']).filter(Boolean);
  const mm = dates.map(d => String(d).slice(0,10)).sort();
  if (mm.length) {
    console.log('[Pantera] Invoice supplement rows:', out.length, 'Date range:', mm[0], 'to', mm[mm.length-1]);
  } else {
    console.log('[Pantera] Invoice supplement rows:', out.length, 'Date range: unknown');
  }
  return out;
}

function integrateInvoiceSupplement(rows) {
  const currentMonth = monthKey(new Date());
  let injected = 0; // diagnostics counter
  let skippedMonth = 0;
  let skippedZeroQty = 0;
  let total = 0;
  // Build quick crosswalks from Items master to recover missing SKU/ID
  const skuById = new Map();
  const nameById = new Map();
  for (const it of state.itemRows) {
    const id = H.itemId(it);
    const sku = H.sku(it);
    const nm = H.itemName(it);
    if (id && sku) skuById.set(String(id), String(sku));
    if (id && nm) nameById.set(String(id), String(nm));
  }
  for (const r of rows) {
    total++;
    // Derive month from Created Time or Last Modified Time
    const created = r['Invoice Date'] || r['Created Time'] || r['Last Modified Time'] || r['Date'];
    let m = null;
    if (created) {
      const mm = String(created).match(/^(\d{4})-(\d{2})/);
      if (mm) m = mm[0];
    }
    if (!m) m = currentMonth; // assume current month if missing
    if (m !== currentMonth) { skippedMonth++; continue; } // only merge current month partials
    const qty = num(r['Quantity'] || r['Qty'] || r['Total_Quantity']);
    if (qty <= 0) { skippedZeroQty++; continue; }
    // Recover identifiers/sku where missing
    const rawId = r['Product ID'] || r['Item_ID'] || r['Item ID'];
    let rawSku = r['SKU'] || r['Item_SKU'];
    if (!rawSku && rawId && skuById.has(String(rawId))) rawSku = skuById.get(String(rawId));
    const rawName = r['Item Name'] || r['Item_Name'] || (rawId && nameById.get(String(rawId))) || '';

    // Convert invoice row into a synthetic sales row for aggregation pipeline
    state.salesRows.push({
      'Item_ID': rawId,
      'Product ID': rawId,
      'Item_SKU': rawSku,
      'Item Name': rawName,
      'Item_Name': rawName,
      'Month_Year': m,
      'Total_Quantity': qty,
      'Net_Sales': num(r['Sub Total (BCY)'] || r['Total (BCY)'] || r['Sales']),
    });
    injected++;
  }
  if (!injected) {
    console.warn('[Pantera] Invoice integration produced ZERO injected rows', { currentMonth, total, skippedMonth, skippedZeroQty });
  } else {
    console.log('[Pantera] Integrated invoice rows for current month:', injected, 'Target month:', currentMonth, 'Total source rows:', total, 'Skipped(other month):', skippedMonth, 'Skipped(qty<=0):', skippedZeroQty);
  }
}

// Debug helper: log raw sales rows contributing to current month for a given SKU
window.debugSku = function(sku){
  const cm = monthKey(new Date());
  const hits = state.salesRows.filter(r => (H.month(r) === cm) && (H.sku(r) || '').trim() === String(sku).trim());
  console.log('[Pantera][debugSku] SKU', sku, 'current month rows:', hits.length, hits);
  const keyHits = Array.from(state.byItem.entries()).filter(([k,v]) => String(v.sku||'').trim() === String(sku).trim());
  if (keyHits.length){
    const [k,v] = keyHits[0];
    console.log('[Pantera][debugSku] Aggregated salesByMonth[current]:', v.salesByMonth[cm], 'Key:', k, v);
  } else {
    console.warn('[Pantera][debugSku] No aggregated item found for SKU', sku);
  }
};

function updateDataStamp(supplementCount) {
  const stampEl = document.getElementById('dataStamp');
  if (!stampEl) return;
  // Determine the latest month with any non-zero quantity across items
  const monthsDesc = [...state.months].reverse(); // recent first
  let latest = monthsDesc.find(m => {
    return Array.from(state.byItem.values()).some(r => (r.salesByMonth[m] || 0) > 0);
  }) || monthsDesc[0];
  const loadedTs = new Date();
  const partialNote = (latest === monthKey(new Date()) && supplementCount > 0) ? ' (partial month)' : '';
  const iso = loadedTs.toISOString().slice(0,19).replace('T',' ');
  stampEl.textContent = `Data current through ${latest}${partialNote} • Loaded ${iso}`;
}

async function resolveSalesFilename() {
  // Build dynamic candidate list: current month (if present), previous month,
  // and a static fallback (Oct 2025 kept for historical compatibility).
  const now = new Date();
  const monthNames = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  const candidates = ['SalesHistory_Updated_Oct2025.csv'];
  const prev = new Date(now.getFullYear(), now.getMonth() - 1, 1);
  const currentName = `SalesHistory_Updated_${monthNames[now.getMonth()]}${now.getFullYear()}.csv`;
  const prevName = `SalesHistory_Updated_${monthNames[prev.getMonth()]}${prev.getFullYear()}.csv`;
  // Try current first (may be partial), then previous, then static fallback
  candidates.unshift(prevName);
  candidates.unshift(currentName);
  for (const c of candidates) {
    const txt = await fetchTextMaybe([`${state.dataBasePath}${c}`, `/${c}`]);
    if (txt) return c;
  }
  return 'SalesHistory_Updated_Oct2025.csv';
}

function init() {
  el.reloadBtn.addEventListener('click', () => loadAll());
  // Theme toggle and initial theme
  applySavedTheme();
  if (el.themeToggle) el.themeToggle.addEventListener('click', toggleTheme);
  if (el.exportFilteredBtn) el.exportFilteredBtn.addEventListener('click', () => exportCsvFiltered());
  if (el.exportAllBtn) el.exportAllBtn.addEventListener('click', () => exportCsvAll());

  // SKU filter wiring
  if (el.applySkusBtn) el.applySkusBtn.addEventListener('click', applySkus);
  if (el.clearSkusBtn) el.clearSkusBtn.addEventListener('click', () => { 
    state.skuFilterSet = null; 
    state.skuFilterPatterns = null;
    state.currentIndex = 0; 
    state.selectedKey = null;
    render(); 
    updatePagerButtons(); 
  });
  // Single SKU lookup
  if (el.lookupBtn) el.lookupBtn.addEventListener('click', () => lookupSku());
  if (el.skuSearch) el.skuSearch.addEventListener('keydown', (e) => { if (e.key === 'Enter') lookupSku(); });
  if (el.showCurrentOnly) el.showCurrentOnly.addEventListener('change', () => { state.showCurrentOnly = el.showCurrentOnly.checked; render(); });
  if (el.prevBtn) el.prevBtn.addEventListener('click', () => { if (state.filteredKeys.length) { state.currentIndex = Math.max(0, state.currentIndex - 1); state.selectedKey = state.filteredKeys[state.currentIndex]; render(); updatePagerButtons(); }});
  if (el.nextBtn) el.nextBtn.addEventListener('click', () => { if (state.filteredKeys.length) { state.currentIndex = Math.min(state.filteredKeys.length - 1, state.currentIndex + 1); state.selectedKey = state.filteredKeys[state.currentIndex]; render(); updatePagerButtons(); }});

  // Delegated row selection: clicking anywhere in a data row selects it
  el.body?.addEventListener('click', (e) => {
    // Don't treat clicks inside inputs as row clicks to avoid re-render/focus loss
    if (e.target.closest('input, textarea, select, button')) return;
    const row = e.target.closest('tr[data-key]');
    if (row && el.body.contains(row)) {
      state.selectedKey = row.getAttribute('data-key');
      if (!state.showCurrentOnly) render();
      renderSummary();
    }
  });
  // Selecting an order input also selects the row
  el.body?.addEventListener('focusin', (e) => {
    const inp = e.target.closest('.order-input');
    if (inp) {
      const key = inp.getAttribute('data-key');
      if (key) { state.selectedKey = key; renderSummary(); }
    }
  });

  // auto-load
  if (maybeGate()) {
    loadAll();
  }
}

init();

function applySkus() {
  const text = (el.skuList?.value || '').trim();
  if (!text) { state.skuFilterSet = null; state.skuFilterPatterns = null; state.currentIndex = 0; render(); updatePagerButtons(); return; }
  const tokens = text.split(/[\s,;]+/).map(s => s.trim()).filter(Boolean);
  state.skuFilterSet = new Set(tokens);
  state.skuFilterPatterns = makeSkuPatterns(tokens);
  state.currentIndex = 0;
  state.selectedKey = null; // force auto-select of first after filter
  render();
  updatePagerButtons();
}

// Build case-insensitive regex patterns from wildcard tokens (supports * and ?)
function makeSkuPatterns(tokens) {
  const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return tokens.map(t => {
    // If token contains * or ?, treat as wildcard; otherwise exact
    const hasWildcard = /[\*\?]/.test(t);
    const body = esc(t).replace(/\\\*/g, '.*').replace(/\\\?/g, '.');
    return new RegExp('^' + body + '$', 'i');
  });
}

function updatePagerButtons() {
  const n = state.filteredKeys.length;
  if (el.prevBtn) el.prevBtn.disabled = !(n > 0 && state.currentIndex > 0);
  if (el.nextBtn) el.nextBtn.disabled = !(n > 0 && state.currentIndex < n - 1);
}

function escapeHtml(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}

// --- persist order qtys ---
function getQtyStore(){
  try {
    const raw = localStorage.getItem('pantera_order_qtys');
    return raw ? JSON.parse(raw) : {};
  } catch { return {}; }
}
function setQtyStore(obj){
  try { localStorage.setItem('pantera_order_qtys', JSON.stringify(obj)); } catch {}
}
function persistOrderQty(key, qty){
  const store = getQtyStore();
  if (qty && qty > 0) store[key] = qty; else delete store[key];
  setQtyStore(store);
}
function applyPersistedOrderQtys(){
  const store = getQtyStore();
  for (const [k, r] of state.byItem.entries()){
    if (store[k] !== undefined) r.orderQty = Number(store[k]) || 0;
  }
}

// --- theme ---
function applySavedTheme(){
  try {
    const t = localStorage.getItem('pantera_theme') || 'light';
    document.body.classList.toggle('dark', t === 'dark');
  } catch {}
}
function toggleTheme(){
  const isDark = document.body.classList.toggle('dark');
  try { localStorage.setItem('pantera_theme', isDark ? 'dark' : 'light'); } catch {}
}

// --- lightweight passcode gate ---
function maybeGate() {
  const required = typeof window.PANTERA_PASSCODE === 'string' && window.PANTERA_PASSCODE.length > 0;
  const lock = document.getElementById('lock');
  if (!required || !lock) return true; // no gate
  // already unlocked this session?
  try {
    if (sessionStorage.getItem('pantera_unlocked') === '1') return true;
  } catch {}

  lock.style.display = 'grid';
  const passInput = document.getElementById('passInput');
  const unlockBtn = document.getElementById('unlockBtn');
  const lockMsg = document.getElementById('lockMsg');
  const tryUnlock = () => {
    const ok = passInput.value === window.PANTERA_PASSCODE;
    if (ok) {
      lock.style.display = 'none';
      try { sessionStorage.setItem('pantera_unlocked','1'); } catch {}
      loadAll();
    } else {
      lockMsg.textContent = 'Invalid passcode';
      passInput.focus();
      passInput.select();
    }
  };
  unlockBtn?.addEventListener('click', tryUnlock);
  passInput?.addEventListener('keydown', (e) => { if (e.key === 'Enter') tryUnlock(); });
  passInput?.focus();
  return false;
}

function renderSummary() {
  const k = state.showCurrentOnly
    ? state.filteredKeys[state.currentIndex]
    : (state.selectedKey || state.filteredKeys[state.currentIndex] || Array.from(state.byItem.keys())[0]);
  const r = state.byItem.get(k);
  if (!r) return;
  // KPIs
  const fmt = (n) => (typeof n === 'number' ? n.toLocaleString() : (n ?? '—'));
  const fmtCRC = (n) => (typeof n === 'number' ? ('CRC ' + n.toLocaleString()) : '—');
  const byId = (id) => document.getElementById(id);
  const dateStr = r._lastPoDate ? new Date(r._lastPoDate).toISOString().slice(0,10) : '—';
  const vendor = r.lastVendor || '—';
  if (byId('kpiLastPrice')) byId('kpiLastPrice').textContent = fmtCRC(r.lastPurchasePrice);
  if (byId('kpiLastDate')) byId('kpiLastDate').textContent = dateStr;
  if (byId('kpiVendor')) byId('kpiVendor').textContent = vendor;
  if (byId('kpiCost')) byId('kpiCost').textContent = fmtCRC(r.cost);
  if (byId('kpiAvailable')) byId('kpiAvailable').textContent = fmt(r.available);
  if (byId('kpiOutstanding')) byId('kpiOutstanding').textContent = fmt(r.outstandingQty);
  const invValue = (r && r.available && r.cost) ? (Number(r.available) * Number(r.cost)) : null;
  if (byId('kpiInventoryValue')) byId('kpiInventoryValue').textContent = fmtCRC(invValue);

  // Current month KPI totals across all items
  const currentMonth = monthKey(new Date());
  let totalQty = 0; let activeItems = 0;
  for (const it of state.byItem.values()) {
    const q = it.salesByMonth[currentMonth] || 0;
    if (q > 0) { activeItems++; totalQty += q; }
  }
  if (byId('kpiCurrentMonthQty')) byId('kpiCurrentMonthQty').textContent = fmt(totalQty);
  if (byId('kpiCurrentMonthItems')) byId('kpiCurrentMonthItems').textContent = `${activeItems.toLocaleString()} items`;

  // Sparkline SVG
  const svg = document.getElementById('sparkline');
  if (!svg) return;
  const W = 600, H = 120, P = 4;
  const vals = state.months.map(m => r.salesByMonth[m] || 0);
  const max = Math.max(1, ...vals);
  const points = vals.map((v, i) => {
    const x = P + (W - 2*P) * (i / (vals.length - 1 || 1));
    const y = H - P - (H - 2*P) * (v / (max || 1));
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(' ');
  svg.innerHTML = `
    <polyline fill="none" stroke="#3f51b5" stroke-width="2" points="${points}" />
    <line x1="0" y1="${H-1}" x2="${W}" y2="${H-1}" stroke="#eee" />
  `;
}

// --- single SKU lookup ---
function lookupSku(){
  const raw = (el.skuSearch?.value || '').trim();
  if (!raw) { showToast('Enter a SKU to look up', 'err'); return; }
  const target = raw.toLowerCase();
  const entries = Array.from(state.byItem.entries());
  const hit = entries.find(([k, v]) => String(v.sku||'').trim().toLowerCase() === target);
  if (!hit) {
    showToast(`SKU not found: ${raw}`, 'err');
    return;
  }
  const [key, row] = hit;
  // Apply a focused filter and show only the current row
  state.skuFilterSet = new Set([row.sku]);
  state.skuFilterPatterns = null;
  state.currentIndex = 0;
  state.selectedKey = key;
  state.showCurrentOnly = true;
  if (el.showCurrentOnly) el.showCurrentOnly.checked = true;
  // Reflect in the multi-SKU textarea for transparency
  if (el.skuList) el.skuList.value = row.sku;
  render();
  updatePagerButtons();
  showToast(`Showing results for SKU ${row.sku}`,'ok');
}

// --- toasts ---
function showToast(message, type='ok'){
  const host = document.getElementById('toast');
  if (!host) return;
  const div = document.createElement('div');
  div.className = `toast ${type==='err'?'err':'ok'}`;
  div.textContent = message;
  host.appendChild(div);
  // Remove after animation (~3s)
  setTimeout(() => { div.remove(); }, 3200);
}
