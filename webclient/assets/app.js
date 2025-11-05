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
};

function setStatus(msg) { el.status.textContent = msg; }

function monthKey(d) { return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}`; }

function computeLast24Months() {
  const now = new Date();
  // Exclude the current month; start from previous month
  const start = new Date(now.getFullYear(), now.getMonth() - 1, 1);
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
        o.lastVendor = H.poVendor(r) || o.lastVendor;
        o.supplierName = H.poVendor(r) || o.supplierName;
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
  const monthCols = monthsDisplay.map(m => ({ key: `m:${m}`, label: m }));
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
      cells.push(`<td class="num">${v ? v.toLocaleString() : ''}</td>`);
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

function exportCsvAll() {
  const rows = Array.from(state.byItem.values());
  const monthsDisplay = [...state.months].reverse();
  const header = ['Item ID','SKU','Item Name','Supplier Code','Available Stock','Inventory Cost','Last Purchase Price','Outstanding PO Qty',...monthsDisplay];
  const data = rows.map(r => [
    r.itemId, r.sku, r.name, r.supplier, r.supplierName || r.lastVendor || '', r.available, r.cost, r.lastPurchasePrice, r.outstandingQty,
    ...monthsDisplay.map(m => r.salesByMonth[m] || 0)
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
  const monthsDisplay = [...state.months].reverse();
  const header = ['Item ID','SKU','Item Name','Supplier Code','Supplier Name','Available Stock','Inventory Cost','Last Purchase Price','Outstanding PO Qty','Order Qty',...monthsDisplay];
  const rows = keys.map(k => state.byItem.get(k)).filter(Boolean);
  const data = rows.map(r => [
    r.itemId, r.sku, r.name, r.supplier, r.supplierName || r.lastVendor || '', r.available, r.cost, r.lastPurchasePrice, r.outstandingQty, r.orderQty || 0,
    ...monthsDisplay.map(m => r.salesByMonth[m] || 0)
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
  const [sales, pos] = await Promise.all([
    loadCsv(salesName),
    loadCsv('Purchase_Order.csv'),
  ]);
  // Items master: allow both "Items.csv" and fallback to "Item.csv"
  let items = await loadCsv('Items.csv');
  if (!items || items.length === 0) {
    items = await loadCsv('Item.csv');
  }
  state.salesRows = sales;
  state.poRows = pos;
  state.itemRows = items;

  aggregate();
  applyPersistedOrderQtys();
  render();
  // Clearer status: aggregated vs items master and total with outstanding POs
  const outstandingCount = Array.from(state.byItem.values()).reduce((n, r) => n + ((r.outstandingQty||0) > 0 ? 1 : 0), 0);
  setStatus(`Aggregated items: ${state.byItem.size.toLocaleString()} • Items master: ${items.length.toLocaleString()} • Outstanding POs: ${outstandingCount.toLocaleString()} items`);
}

async function resolveSalesFilename() {
  // Prefer explicit 2025 Oct file name pattern, else fallback to SalesHistory_Updated_Oct2025.csv
  const candidates = [
    'SalesHistory_Updated_Oct2025.csv',
  ];
  // Also generate guess for current month label
  const now = new Date();
  const monthNames = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
  // Use previous month to avoid selecting a month with no data yet
  const prev = new Date(now.getFullYear(), now.getMonth() - 1, 1);
  candidates.unshift(`SalesHistory_Updated_${monthNames[prev.getMonth()]}${prev.getFullYear()}.csv`);
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
  const byId = (id) => document.getElementById(id);
  const dateStr = r._lastPoDate ? new Date(r._lastPoDate).toISOString().slice(0,10) : '—';
  const vendor = r.lastVendor || '—';
  if (byId('kpiLastPrice')) byId('kpiLastPrice').textContent = fmt(r.lastPurchasePrice);
  if (byId('kpiLastDate')) byId('kpiLastDate').textContent = dateStr;
  if (byId('kpiVendor')) byId('kpiVendor').textContent = vendor;
  if (byId('kpiCost')) byId('kpiCost').textContent = fmt(r.cost);
  if (byId('kpiAvailable')) byId('kpiAvailable').textContent = fmt(r.available);
  if (byId('kpiOutstanding')) byId('kpiOutstanding').textContent = fmt(r.outstandingQty);
  const invValue = (r && r.available && r.cost) ? (Number(r.available) * Number(r.cost)) : null;
  if (byId('kpiInventoryValue')) byId('kpiInventoryValue').textContent = fmt(invValue);

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
