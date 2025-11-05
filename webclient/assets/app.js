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
  filteredKeys: [],
  currentIndex: 0,
  showCurrentOnly: false,
};

const el = {
  status: document.getElementById('status'),
  reloadBtn: document.getElementById('reloadBtn'),
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
};

function setStatus(msg) { el.status.textContent = msg; }

function monthKey(d) { return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}`; }

function computeLast24Months() {
  const now = new Date();
  const start = new Date(now.getFullYear(), now.getMonth(), 1);
  const months = [];
  for (let i=23; i>=0; i--) {
    const d = new Date(start.getFullYear(), start.getMonth()-i, 1);
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
  // Items master
  available: (r) => num(r['Available_Stock'] || r['Available Stock'] || r['AvailableQuantity'] || r['Available Qty'] || r['Stock Available'] || r['Available']),
  cost: (r) => num(r['Cost'] || r['Rate'] || r['Average Cost'] || r['Inventory Cost']),
};

function num(v) {
  if (v === undefined || v === null || v === '') return 0;
  if (typeof v === 'number') return v;
  const s = String(v).replace(/[,\s]/g, '');
  const n = Number(s);
  return isFinite(n) ? n : 0;
}

function parseDate(s) {
  if (!s) return null;
  // Try YYYY-MM or YYYY-MM-DD
  const m = String(s).match(/^(\d{4})-(\d{2})(?:-(\d{2}))?/);
  if (m) return new Date(Number(m[1]), Number(m[2])-1, m[3]?Number(m[3]):1);
  const d = new Date(s);
  return isNaN(d) ? null : d;
}

function makeKey(r) {
  const sku = H.sku(r);
  const id = H.itemId(r);
  if (sku && id) return `${sku}__${id}`;
  return sku || id || H.itemName(r) || JSON.stringify(r).slice(0,64);
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
      }
    }
  }
}

function baseItem(r) {
  const obj = {
    itemId: H.itemId(r) || '',
    sku: H.sku(r) || '',
    name: H.itemName(r) || '',
    supplier: H.supplierCode(r) || '',
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
    { key: 'available', label: 'Available Stock' },
    { key: 'cost', label: 'Inventory Cost' },
    { key: 'lastPurchasePrice', label: 'Last Purchase Price' },
    { key: 'outstandingQty', label: 'Outstanding PO Qty' },
    { key: 'orderQty', label: 'Order Qty' },
  ];
  const monthCols = state.months.map(m => ({ key: `m:${m}`, label: m }));
  const cols = [...staticCols, ...monthCols];

  // Render header
  el.head.innerHTML = '<tr>' + cols.map(c => `<th>${c.label}</th>`).join('') + '</tr>';

  // Rows
  let entries = Array.from(state.byItem.entries());
  // Apply SKU filter if present
  if (state.skuFilterSet && state.skuFilterSet.size > 0) {
    entries = entries.filter(([k, v]) => v.sku && state.skuFilterSet.has(String(v.sku).trim()));
  }
  state.filteredKeys = entries.map(([k]) => k);

  const rows = entries.map(([, v]) => v);
  const html = [];
  rows.forEach((r, idx) => {
    const cells = [];
    for (const c of staticCols) {
      let v = r[c.key];
      if (c.key === 'orderQty') {
        cells.push(`<td><input type="number" class="order-input" data-key="${escapeHtml(makeKey(r))}" value="${r.orderQty ?? ''}" min="0" step="1"></td>`);
        continue;
      }
      if (typeof v === 'number') v = v.toLocaleString();
      cells.push(`<td>${v ?? ''}</td>`);
    }
    for (const m of state.months) {
      const v = r.salesByMonth[m] || 0;
      cells.push(`<td class="num">${v ? v.toLocaleString() : ''}</td>`);
    }
    const isCurrent = state.showCurrentOnly && state.filteredKeys[state.currentIndex] === makeKey(r);
    html.push(`<tr class="${isCurrent ? 'current-row' : ''}">${cells.join('')}</tr>`);
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
      if (row) row.orderQty = num(inp.value);
    });
  });

  // Update pager label
  el.pagerLabel.textContent = `${Math.min(state.currentIndex+1, Math.max(1, state.filteredKeys.length))} of ${state.filteredKeys.length}`;
}

function exportCsvAll() {
  const rows = Array.from(state.byItem.values());
  const header = ['Item ID','SKU','Item Name','Supplier Code','Available Stock','Inventory Cost','Last Purchase Price','Outstanding PO Qty',...state.months];
  const data = rows.map(r => [
    r.itemId, r.sku, r.name, r.supplier, r.available, r.cost, r.lastPurchasePrice, r.outstandingQty,
    ...state.months.map(m => r.salesByMonth[m] || 0)
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
  const header = ['Item ID','SKU','Item Name','Supplier Code','Available Stock','Inventory Cost','Last Purchase Price','Outstanding PO Qty','Order Qty',...state.months];
  const rows = keys.map(k => state.byItem.get(k)).filter(Boolean);
  const data = rows.map(r => [
    r.itemId, r.sku, r.name, r.supplier, r.available, r.cost, r.lastPurchasePrice, r.outstandingQty, r.orderQty || 0,
    ...state.months.map(m => r.salesByMonth[m] || 0)
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
  computeLast24Months();

  const salesName = await resolveSalesFilename();
  const [sales, pos, items] = await Promise.all([
    loadCsv(salesName),
    loadCsv('Purchase_Order.csv'),
    loadCsv('Items.csv'),
  ]);
  state.salesRows = sales;
  state.poRows = pos;
  state.itemRows = items;

  aggregate();
  render();
  setStatus(`Loaded ${state.byItem.size} items | Sales ${sales.length} | POs ${pos.length} | Items ${items.length}`);
}

async function resolveSalesFilename() {
  // Prefer explicit 2025 Oct file name pattern, else fallback to SalesHistory_Updated_Oct2025.csv
  const candidates = [
    'SalesHistory_Updated_Oct2025.csv',
  ];
  // Also generate guess for current month label
  const now = new Date();
  const monthNames = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  candidates.unshift(`SalesHistory_Updated_${monthNames[now.getMonth()]}${now.getFullYear()}.csv`);
  for (const c of candidates) {
    const txt = await fetchTextMaybe([`${state.dataBasePath}${c}`, `/${c}`]);
    if (txt) return c;
  }
  return 'SalesHistory_Updated_Oct2025.csv';
}

function init() {
  el.reloadBtn.addEventListener('click', () => loadAll());
  if (el.exportFilteredBtn) el.exportFilteredBtn.addEventListener('click', () => exportCsvFiltered());
  if (el.exportAllBtn) el.exportAllBtn.addEventListener('click', () => exportCsvAll());

  // SKU filter wiring
  if (el.applySkusBtn) el.applySkusBtn.addEventListener('click', applySkus);
  if (el.clearSkusBtn) el.clearSkusBtn.addEventListener('click', () => { state.skuFilterSet = null; state.currentIndex = 0; render(); updatePagerButtons(); });
  if (el.showCurrentOnly) el.showCurrentOnly.addEventListener('change', () => { state.showCurrentOnly = el.showCurrentOnly.checked; render(); });
  if (el.prevBtn) el.prevBtn.addEventListener('click', () => { if (state.filteredKeys.length) { state.currentIndex = Math.max(0, state.currentIndex - 1); render(); updatePagerButtons(); }});
  if (el.nextBtn) el.nextBtn.addEventListener('click', () => { if (state.filteredKeys.length) { state.currentIndex = Math.min(state.filteredKeys.length - 1, state.currentIndex + 1); render(); updatePagerButtons(); }});

  // auto-load
  loadAll();
}

init();

function applySkus() {
  const text = (el.skuList?.value || '').trim();
  if (!text) { state.skuFilterSet = null; state.currentIndex = 0; render(); updatePagerButtons(); return; }
  const tokens = text.split(/[\s,;]+/).map(s => s.trim()).filter(Boolean);
  state.skuFilterSet = new Set(tokens);
  state.currentIndex = 0;
  render();
  updatePagerButtons();
}

function updatePagerButtons() {
  const n = state.filteredKeys.length;
  if (el.prevBtn) el.prevBtn.disabled = !(n > 0 && state.currentIndex > 0);
  if (el.nextBtn) el.nextBtn.disabled = !(n > 0 && state.currentIndex < n - 1);
}

function escapeHtml(s) {
  return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}
