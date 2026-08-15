const form = document.querySelector('#bot-form');
const consoleBox = document.querySelector('#console');
const commandBox = document.querySelector('#command');
const statusBox = document.querySelector('#run-status');
const modePill = document.querySelector('#mode-pill');
const stopButton = document.querySelector('#stop');
const presetSelect = document.querySelector('#preset-select');
let currentRunId = null;
let symbolRows = [];
let currentStrategyPoints = [];
let currentBenchmarkPoints = [];
let currentRawOutput = '';
let currentDataJobId = null;
let currentDataRawOutput = '';

const metrics = {
  cagr: document.querySelector('#metric-cagr'), pf: document.querySelector('#metric-pf'),
  maxdd: document.querySelector('#metric-maxdd'), winrate: document.querySelector('#metric-winrate'),
  trades: document.querySelector('#metric-trades'), equity: document.querySelector('#metric-equity')
};

function payload() {
  const data = Object.fromEntries(new FormData(form));
  data.one_trade = form.elements.one_trade.checked;
  return data;
}

async function jsonPost(url) {
  const response = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload()) });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'Request failed');
  return data;
}

function setStatus(text, kind) {
  statusBox.textContent = text.toUpperCase();
  statusBox.className = `run-status ${kind}`;
}

function consoleDisplayText(text) {
  const raw = String(text || '');
  if (document.querySelector('#console-view')?.value === 'full') return raw;
  let display = raw
    .replace(/\x1B(?:[@-Z\\-_]|\[[0-?]*[ -\/]*[@-~])/g, '')
    .replace(/_GoogleFinance_AutoUpToDate/gi, '')
    .replace(/[A-Z]:[\\\/][^\r\n]*?Trading_Bot_Officiel[\\\/]/gi, '');
  const isSweep = raw.split(/\r?\n/, 1)[0]?.includes('--sweep');
  const hiddenCommonLine = line =>
    /^\s*\$\s/.test(line) ||
    /^\s*🔍/.test(line) ||
    /^\s*\[(?:BOOT|FCX_VOL|EARLY ENV|DEBUG PARAMS|STORAGE)\]/.test(line) ||
    /:\d+: warning: (?:already initialized constant|previous definition)/.test(line);
  const hiddenBacktestLine = line =>
    /^\s*\[BOT_METRICS\].*fallback metrics written for tuner/i.test(line) ||
    /^\s*\[BOT_METRICS\]/i.test(line) ||
    /^\s*\[REGIME\]\s+Benchmark\s+VXX\s+missing/i.test(line) ||
    /^\s*\[VIXY(?:\s+FAST)?\s+PANIC\]/i.test(line) ||
    /^\s*\[[A-Z0-9]+_STOP_(?:TRIGGERED|NEXT_OPEN)\]/i.test(line) ||
    /^\s*\[HARD_STOP\]/i.test(line) ||
    /^\s*\[(?:SAVED|CLONED)\]/i.test(line) ||
    /^\s*\[DONE\].*\bsaved\b/i.test(line) ||
    /^\s*\[INFO\]\s+No completed manual trades/i.test(line) ||
    /^\s*🧹\s+Deleted old multi-signal/i.test(line) ||
    /^\s*✅\s+Deduplicated\b/i.test(line) ||
    /^\s*-{3,}\s*$/.test(line) ||
    /^\s*(?:BUY|SELL)\s+\S+\s+\d{4}-\d{2}-\d{2}T/i.test(line) ||
    /^\s*\[REASON\]/i.test(line);
  let insideDefaultConfiguration = false;
  let insideLegacyOrderVerification = false;
  let orderVerificationSeparators = 0;
  let insidePerformanceComparison = false;
  display = display
    .split(/\r?\n/)
    .filter(line => {
      if (/Performance Comparison\s*\(CAGR\s*%\)/i.test(line)) {
        insidePerformanceComparison = true;
        return false;
      }
      if (insidePerformanceComparison) {
        if (/^\s*\[BOT_METRICS\]/i.test(line)) insidePerformanceComparison = false;
        else return false;
      }
      if (/ACTIVE CONFIGURATION/i.test(line)) {
        insideDefaultConfiguration = true;
        return false;
      }
      if (insideDefaultConfiguration) {
        if (/^\s*=+\s*$/.test(line)) insideDefaultConfiguration = false;
        return false;
      }
      if (/VERIFY TOMORROW ORDERS/i.test(line)) {
        insideLegacyOrderVerification = true;
        orderVerificationSeparators = 0;
        return false;
      }
      if (insideLegacyOrderVerification) {
        if (/^\s*-{5,}\s*$/.test(line)) orderVerificationSeparators += 1;
        if (orderVerificationSeparators >= 2) insideLegacyOrderVerification = false;
        return false;
      }
      return !hiddenCommonLine(line) && (isSweep || !hiddenBacktestLine(line));
    })
    .join('\n');
  return display.replace(/\n{3,}/g, '\n\n').trimStart();
}

function lastValue(text, patterns) {
  for (const pattern of patterns) {
    const matches = [...text.matchAll(pattern)];
    if (matches.length) return matches.at(-1)[1];
  }
  return null;
}

function updateMetrics(text) {
  const found = {
    cagr: lastValue(text, [/CAGR\s*[=:]\s*\$?(-?[\d,.]+)%?/gi]),
    pf: lastValue(text, [/(?:PF|Profit\s*Factor)\s*[=:]\s*(-?[\d,.]+)/gi]),
    maxdd: lastValue(text, [/(?:MaxDD|Max\s*Drawdown)\s*[=:]\s*(-?[\d,.]+)%?/gi]),
    winrate: lastValue(text, [/(?:WinRate|Win\s*Rate)\s*[=:]\s*(-?[\d,.]+)%?/gi]),
    trades: lastValue(text, [/(?:Trades|Total\s*Trades)\s*[=:]\s*(\d+)/gi]),
    equity: lastValue(text, [/(?:FinalEquity|Final\s*Equity)\s*[=:]\s*\$?([\d,.]+)/gi])
  };
  if (found.cagr !== null) metrics.cagr.textContent = `${found.cagr}%`;
  if (found.pf !== null) metrics.pf.textContent = found.pf.replace(/,+$/, '');
  if (found.maxdd !== null) metrics.maxdd.textContent = `${found.maxdd}%`;
  if (found.winrate !== null) metrics.winrate.textContent = `${found.winrate}%`;
  if (found.trades !== null) metrics.trades.textContent = found.trades;
  if (found.equity !== null) metrics.equity.textContent = `$${found.equity}`;
}

function equityPoints(text) {
  if (Array.isArray(text)) return text.map(point => ({ label: String(point.label || point.year || ''), equity: Number(point.equity), symbol: point.symbol || '' })).filter(point => point.label && Number.isFinite(point.equity));
  const byYear = new Map();
  const clean = text.replace(/\x1B(?:[@-Z\\-_]|\[[0-?]*[ -\/]*[@-~])/g, '');
  clean.split(/\r?\n/).forEach(line => {
    const yearMatch = line.match(/\b(20\d{2})\b/);
    if (!yearMatch) return;
    const money = [...line.matchAll(/\$\s*([\d,]+(?:\.\d+)?)/g)];
    if (money.length < 2) return;
    byYear.set(Number(yearMatch[1]), Number(money[1][1].replaceAll(',', '')));
  });
  return [...byYear].map(([year, equity]) => ({ label: String(year), equity, symbol: '' })).filter(point => Number.isFinite(point.equity)).sort((a, b) => Number(a.label) - Number(b.label));
}

function updateEquityChart(text, benchmark = currentBenchmarkPoints) {
  const points = equityPoints(text);
  currentStrategyPoints = points;
  currentBenchmarkPoints = equityPoints(benchmark);
  const showBenchmark = document.querySelector('#benchmark-toggle').checked && currentBenchmarkPoints.length > 0;
  const benchmarkControl = document.querySelector('#benchmark-toggle');
  benchmarkControl.disabled = currentBenchmarkPoints.length === 0;
  benchmarkControl.closest('label').title = currentBenchmarkPoints.length ? 'Show or hide QQQ buy-and-hold' : 'QQQ CSV data was not found or could not be read';
  const empty = document.querySelector('#chart-empty');
  const line = document.querySelector('#chart-line');
  const area = document.querySelector('#chart-area');
  const benchmarkLine = document.querySelector('#benchmark-line');
  const grid = document.querySelector('#chart-grid');
  const dots = document.querySelector('#chart-points');
  const labels = document.querySelector('#chart-labels');
  [grid, dots, labels].forEach(element => { element.innerHTML = ''; });
  if (!points.length) { empty.style.display = 'grid'; line.setAttribute('points', ''); benchmarkLine.setAttribute('points', ''); area.setAttribute('d', ''); return; }

  empty.style.display = 'none';
  const width = 800, height = 260, left = 68, right = 22, top = 18, bottom = 38;
  const values = points.map(point => point.equity).concat(showBenchmark ? currentBenchmarkPoints.map(point => point.equity) : []);
  const low = Math.min(...values), high = Math.max(...values);
  const padding = Math.max((high - low) * .12, high * .04, 1);
  const min = Math.max(0, low - padding), max = high + padding;
  const time = value => {
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? parsed : Number(String(value).slice(0, 4));
  };
  const allTimelinePoints = points.concat(showBenchmark ? currentBenchmarkPoints : []);
  const timeline = allTimelinePoints.map(point => time(point.label)).filter(Number.isFinite);
  const minTime = Math.min(...timeline), maxTime = Math.max(...timeline);
  const xFor = (point, index) => {
    const pointTime = time(point.label);
    if (Number.isFinite(pointTime) && maxTime !== minTime) return left + (pointTime - minTime) * (width - left - right) / (maxTime - minTime);
    return points.length === 1 ? (left + width - right) / 2 : left + index * (width - left - right) / (points.length - 1);
  };
  const y = value => top + (max - value) * (height - top - bottom) / Math.max(max - min, 1);
  const ns = 'http://www.w3.org/2000/svg';

  for (let i = 0; i <= 4; i += 1) {
    const gy = top + i * (height - top - bottom) / 4;
    const gridLine = document.createElementNS(ns, 'line'); gridLine.setAttribute('x1', left); gridLine.setAttribute('x2', width - right); gridLine.setAttribute('y1', gy); gridLine.setAttribute('y2', gy); grid.appendChild(gridLine);
    const label = document.createElementNS(ns, 'text'); label.setAttribute('x', left - 9); label.setAttribute('y', gy + 4); label.setAttribute('text-anchor', 'end'); label.textContent = `$${Math.round(max - i * (max - min) / 4).toLocaleString()}`; labels.appendChild(label);
  }

  const coords = points.map((point, index) => `${xFor(point, index)},${y(point.equity)}`);
  line.setAttribute('points', coords.join(' '));
  if (showBenchmark) {
    benchmarkLine.setAttribute('points', currentBenchmarkPoints.map((point, index) => `${xFor(point, index)},${y(point.equity)}`).join(' '));
  } else benchmarkLine.setAttribute('points', '');
  area.setAttribute('d', `M ${xFor(points[0], 0)} ${height - bottom} L ${coords.join(' L ')} L ${xFor(points.at(-1), points.length - 1)} ${height - bottom} Z`);
  points.forEach((point, index) => {
    const dot = document.createElementNS(ns, 'circle'); dot.setAttribute('cx', xFor(point, index)); dot.setAttribute('cy', y(point.equity)); dot.setAttribute('r', points.length > 60 ? 2 : 3.5); const title = document.createElementNS(ns, 'title'); title.textContent = `${point.label}${point.symbol ? ` · ${point.symbol}` : ''}: $${point.equity.toLocaleString(undefined, { maximumFractionDigits: 2 })}`; dot.appendChild(title); dots.appendChild(dot);
  });
  if (Number.isFinite(minTime) && Number.isFinite(maxTime)) {
    const startYear = new Date(minTime).getUTCFullYear(), endYear = new Date(maxTime).getUTCFullYear();
    const yearStep = Math.max(1, Math.ceil((endYear - startYear + 1) / 8));
    for (let year = startYear; year <= endYear; year += yearStep) {
      const yearTime = year === startYear ? minTime : Date.UTC(year, 0, 1);
      if (yearTime > maxTime) continue;
      const yearX = maxTime === minTime ? (left + width - right) / 2 : left + (yearTime - minTime) * (width - left - right) / (maxTime - minTime);
      const label = document.createElementNS(ns, 'text'); label.setAttribute('x', yearX); label.setAttribute('y', height - 14); label.setAttribute('text-anchor', year === startYear ? 'start' : 'middle'); label.textContent = String(year); labels.appendChild(label);
    }
  }
}

function resultValue(text, label) {
  const match = text.match(new RegExp(`(?:${label})\\s*[=:]\\s*\\$?(-?[\\d,.]+)%?`, 'i'));
  return match ? match[1] : '—';
}

function updateSymbolResults(text) {
  const rows = new Map();
  text.split(/\r?\n/).filter(line => line.includes('[RESULT]')).forEach(line => {
    const match = line.match(/\[RESULT\]\s+([^|\s]+)/i);
    if (!match) return;
    const symbol = match[1].split('_')[0];
    rows.set(symbol, { symbol, trades: resultValue(line, 'Trades'), pf: resultValue(line, 'PF|Profit\\s*Factor'), cagr: resultValue(line, 'CAGR'), winrate: resultValue(line, 'WinRate|Win\\s*Rate') });
  });
  const selectedSymbols = form.elements.symbols.value.trim().split(/[\s,]+/).filter(Boolean);
  if (!rows.size && selectedSymbols.length === 1 && /(?:CONFIG SUMMARY|Final Rank|Trades\s*:)/i.test(text)) {
    const symbol = selectedSymbols[0].toUpperCase().split('_')[0];
    rows.set(symbol, {
      symbol,
      trades: lastValue(text, [/(?:Trades|Total\s*Trades)\s*[=:]\s*(\d+)/gi]) || '—',
      pf: lastValue(text, [/(?:PF|Profit\s*Factor)\s*[=:]\s*(-?[\d,.]+)/gi]) || '—',
      cagr: lastValue(text, [/CAGR\s*[=:]\s*\$?(-?[\d,.]+)%?/gi]) || '—',
      winrate: lastValue(text, [/(?:WinRate|Win\s*Rate|Win)\s*[=:]\s*(-?[\d,.]+)%?/gi]) || '—'
    });
  }
  renderSymbolResults([...rows.values()].map(row => ({ symbol: row.symbol, trades: row.trades, pf: row.pf, cagr: row.cagr, win_rate: row.winrate, compounded_return: '—' })));
}

function renderSymbolResults(rows) {
  const body = document.querySelector('#results-body');
  body.innerHTML = '';
  if (!rows.length) body.innerHTML = '<tr class="empty"><td colspan="6">Run a backtest to populate this table.</td></tr>';
  else rows.forEach(row => {
    const tr = document.createElement('tr');
    const pf = row.pf === null || row.pf === undefined ? '∞' : row.pf;
    const cagr = row.cagr === null || row.cagr === undefined || row.cagr === '—' ? '—' : `${row.cagr}%`;
    const winRate = row.win_rate === null || row.win_rate === undefined || row.win_rate === '—' ? '—' : `${row.win_rate}%`;
    const compounded = row.compounded_return === null || row.compounded_return === undefined || row.compounded_return === '—' ? '—' : `${row.compounded_return}%`;
    [row.symbol, row.trades, pf, cagr, winRate, compounded].forEach(item => {
      const td = document.createElement('td'); td.textContent = item; tr.appendChild(td);
    });
    body.appendChild(tr);
  });
  document.querySelector('#result-count').textContent = `${rows.length} symbol${rows.length === 1 ? '' : 's'}`;
}

function renderTomorrowSignals(rows) {
  const body = document.querySelector('#signals-body');
  body.innerHTML = '';
  if (!Array.isArray(rows) || !rows.length) {
    body.innerHTML = '<tr class="empty"><td colspan="5">No rows found in tomorrow_orders.csv.</td></tr>';
    document.querySelector('#signal-count').textContent = '0 orders';
    return;
  }
  rows.forEach(row => {
    const tr = document.createElement('tr');
    const symbol = document.createElement('td'); symbol.textContent = row.symbol || '—';
    const signal = document.createElement('td'); signal.textContent = row.signal || '—'; signal.className = `signal-${String(row.signal || '').toLowerCase()}`;
    const price = document.createElement('td'); price.textContent = row.price === null || row.price === undefined ? '—' : `$${Number(row.price).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
    const date = document.createElement('td'); date.textContent = row.date || '—';
    const execution = document.createElement('td'); execution.textContent = row.execution || 'Next open';
    [symbol, signal, price, date, execution].forEach(cell => tr.appendChild(cell)); body.appendChild(tr);
  });
  document.querySelector('#signal-count').textContent = `${rows.length} order${rows.length === 1 ? '' : 's'}`;
}

function renderRecentSignals(rows) {
  const body = document.querySelector('#recent-signals-body');
  body.innerHTML = '';
  if (!Array.isArray(rows) || !rows.length) {
    body.innerHTML = '<tr class="empty"><td colspan="4">No recent signal lines found in the selected run.</td></tr>';
    document.querySelector('#recent-signal-count').textContent = '0 signals';
    return;
  }
  rows.forEach(row => {
    const tr = document.createElement('tr');
    const symbol = document.createElement('td'); symbol.textContent = row.symbol || '—';
    const signal = document.createElement('td'); signal.textContent = row.signal || '—'; signal.className = `signal-${String(row.signal || '').toLowerCase()}`;
    const price = document.createElement('td'); price.textContent = row.price === null || row.price === undefined ? '—' : `$${Number(row.price).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
    const date = document.createElement('td'); date.textContent = row.date || '—';
    [symbol, signal, price, date].forEach(cell => tr.appendChild(cell)); body.appendChild(tr);
  });
  document.querySelector('#recent-signal-count').textContent = `${rows.length} signal${rows.length === 1 ? '' : 's'}`;
}

function applyRunData(run) {
  currentRawOutput = run.output || '';
  consoleBox.textContent = consoleDisplayText(currentRawOutput);
  consoleBox.scrollTop = consoleBox.scrollHeight;
  updateMetrics(run.output || '');
  const nextOpen = run.next_open_metrics || {};
  metrics.cagr.textContent = nextOpen.cagr !== undefined ? `${nextOpen.cagr}%` : '—';
  metrics.pf.textContent = nextOpen.pf !== undefined ? nextOpen.pf : '—';
  metrics.maxdd.textContent = nextOpen.maxdd !== undefined ? `${nextOpen.maxdd}%` : '—';
  metrics.winrate.textContent = nextOpen.winrate !== undefined ? `${nextOpen.winrate}%` : '—';
  metrics.trades.textContent = nextOpen.trades !== undefined ? nextOpen.trades : '—';
  if (run.final_equity !== null && run.final_equity !== undefined) metrics.equity.textContent = `$${Number(run.final_equity).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
  const detailed = Array.isArray(run.trade_equity_points) && run.trade_equity_points.length > 1;
  updateEquityChart(detailed ? run.trade_equity_points : (run.equity_points || []), run.benchmark_points || []);
  const benchmarkStatus = document.querySelector('#benchmark-status');
  benchmarkStatus.textContent = run.benchmark_status || 'QQQ status unavailable.';
  benchmarkStatus.classList.toggle('ready', Array.isArray(run.benchmark_points) && run.benchmark_points.length > 0);
  benchmarkStatus.classList.toggle('problem', !Array.isArray(run.benchmark_points) || run.benchmark_points.length === 0);
  if (Array.isArray(run.symbol_results) && run.symbol_results.length) renderSymbolResults(run.symbol_results); else updateSymbolResults(run.output || '');
  renderTomorrowSignals(run.tomorrow_signals || []);
  renderRecentSignals(run.recent_signals || []);
}

document.querySelector('#console-view').addEventListener('change', () => {
  consoleBox.textContent = consoleDisplayText(currentRawOutput);
  consoleBox.scrollTop = consoleBox.scrollHeight;
});

function resetMetrics() { Object.values(metrics).forEach(element => { element.textContent = '—'; }); currentBenchmarkPoints = []; updateEquityChart('', []); }

function historyStatusClass(status) {
  return ['finished', 'running', 'stopped', 'failed', 'error'].includes(status) ? status : 'unknown';
}
async function openHistoricalRun(runId) {
  try {
    const response = await fetch(`/api/run/${runId}`, { cache: 'no-store' });
    const run = await response.json();
    if (!response.ok) throw new Error(run.error || 'Could not open run');
    applyRunData(run);
    setStatus('History', 'idle');
    document.querySelector('#dashboard').scrollIntoView({ behavior: 'smooth' });
  } catch (error) { alert(error.message); }
}
async function loadRunHistory() {
  const body = document.querySelector('#history-body');
  try {
    const response = await fetch('/api/runs', { cache: 'no-store' });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || 'Could not load history');
    body.innerHTML = '';
    if (!data.runs.length) { body.innerHTML = '<tr class="empty"><td colspan="6">No GUI runs saved yet.</td></tr>'; return; }
    data.runs.forEach(run => {
      const tr = document.createElement('tr');
      const name = document.createElement('td'); name.textContent = run.name || '—'; name.className = 'history-name';
      const date = document.createElement('td'); date.textContent = run.started_at ? new Date(run.started_at).toLocaleString() : '—';
      const symbols = document.createElement('td'); const list = Array.isArray(run.symbols) ? run.symbols : []; symbols.textContent = list.length > 4 ? `${list.slice(0, 4).join(', ')} +${list.length - 4}` : (list.join(', ') || '—'); symbols.title = list.join(', ');
      const mode = document.createElement('td'); mode.textContent = String(run.mode || 'backtest').toUpperCase();
      const status = document.createElement('td'); const badge = document.createElement('span'); badge.className = `history-status ${historyStatusClass(run.status)}`; badge.textContent = String(run.status || 'unknown').toUpperCase(); status.appendChild(badge);
      const action = document.createElement('td'); action.className = 'history-actions';
      const open = document.createElement('button'); open.type = 'button'; open.className = 'history-open'; open.textContent = 'Open'; open.addEventListener('click', () => openHistoricalRun(run.id));
      const rename = document.createElement('button'); rename.type = 'button'; rename.className = 'history-open'; rename.textContent = 'Name'; rename.addEventListener('click', async () => {
        const newName = prompt('Name this run:', run.name || '')?.trim(); if (newName === undefined) return;
        const response = await fetch(`/api/run/${run.id}/name`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ name: newName }) });
        const result = await response.json(); if (!response.ok) return alert(result.error || 'Could not name run'); loadRunHistory();
      });
      const remove = document.createElement('button'); remove.type = 'button'; remove.className = 'history-delete'; remove.textContent = 'Delete'; remove.addEventListener('click', async () => {
        if (!confirm(`Delete this saved run${run.name ? ` "${run.name}"` : ''}? Its log and trade snapshot will be removed.`)) return;
        const response = await fetch(`/api/run/${run.id}`, { method: 'DELETE' }); const result = await response.json();
        if (!response.ok) return alert(result.error || 'Could not delete run'); loadRunHistory();
      });
      action.append(open, rename, remove);
      [name, date, symbols, mode, status, action].forEach(cell => tr.appendChild(cell)); body.appendChild(tr);
    });
  } catch (error) { body.innerHTML = `<tr class="empty"><td colspan="6">${error.message}</td></tr>`; }
}
document.querySelector('#refresh-history').addEventListener('click', loadRunHistory);
document.querySelector('#clear-history').addEventListener('click', async () => {
  if (!confirm('Delete all saved run logs and trade snapshots? Presets and live positions will not be affected. This cannot be undone.')) return;
  if (!confirm('Are you sure you want to clear all run history?')) return;
  try {
    const response = await fetch('/api/runs', { method: 'DELETE' }); const result = await response.json();
    if (!response.ok) throw new Error(result.error || 'Could not clear history');
    loadRunHistory(); alert(`Deleted ${result.deleted} saved run${result.deleted === 1 ? '' : 's'}.${result.active_preserved ? ' The active run was preserved.' : ''}`);
  } catch (error) { alert(error.message); }
});

document.querySelector('#benchmark-toggle').addEventListener('change', () => updateEquityChart(currentStrategyPoints, currentBenchmarkPoints));

function savedPositions() {
  try { return JSON.parse(localStorage.getItem('tradingBotPositions') || '[]'); } catch { return []; }
}
function storePositions(rows) { localStorage.setItem('tradingBotPositions', JSON.stringify(rows)); }
function money(value) { const number = Number(value); return Number.isFinite(number) ? `$${number.toFixed(2)}` : '—'; }
function positionInput(value, type, placeholder, onChange) {
  const input = document.createElement('input');
  input.type = type; input.value = value ?? ''; input.placeholder = placeholder;
  if (type === 'number') { input.step = 'any'; input.min = '0'; }
  input.addEventListener('change', onChange);
  return input;
}
function renderPositions() {
  const body = document.querySelector('#positions-body');
  const rows = savedPositions();
  body.innerHTML = '';
  let totalValue = 0, totalCost = 0;
  if (!rows.length) body.innerHTML = '<tr class="empty"><td colspan="9">No open positions. Click “Add Position” to track one.</td></tr>';
  rows.forEach((row, index) => {
    const tr = document.createElement('tr');
    const shares = Number(row.shares), entry = Number(row.entry), current = Number(row.current);
    const percent = entry > 0 && Number.isFinite(current) ? ((current / entry) - 1) * 100 : null;
    const marketValue = Number.isFinite(shares) && Number.isFinite(current) ? shares * current : 0;
    const cost = Number.isFinite(shares) && Number.isFinite(entry) ? shares * entry : 0;
    const dollarPl = marketValue - cost;
    totalValue += marketValue; totalCost += cost;
    const saveField = field => event => { const next = savedPositions(); next[index][field] = field === 'ticker' ? event.target.value.trim().toUpperCase() : event.target.value; storePositions(next); renderPositions(); };
    [[row.ticker, 'text', 'VST', 'ticker'], [row.shares, 'number', '0', 'shares'], [row.entry, 'number', '0.00', 'entry'], [row.current, 'number', '0.00', 'current']].forEach(([value, type, placeholder, field]) => {
      const td = document.createElement('td'); td.appendChild(positionInput(value, type, placeholder, saveField(field))); tr.appendChild(td);
    });
    const valueCell = document.createElement('td'); valueCell.textContent = money(marketValue); tr.appendChild(valueCell);
    const dollarCell = document.createElement('td'); dollarCell.textContent = `${dollarPl >= 0 ? '+' : ''}${money(dollarPl)}`; dollarCell.className = dollarPl >= 0 ? 'position-profit' : 'position-loss'; tr.appendChild(dollarCell);
    const pl = document.createElement('td'); pl.textContent = percent === null ? '—' : `${percent >= 0 ? '+' : ''}${percent.toFixed(2)}%`; pl.className = percent === null ? '' : (percent >= 0 ? 'position-profit' : 'position-loss'); tr.appendChild(pl);
    const stop = document.createElement('td'); stop.appendChild(positionInput(row.stop, 'number', '0.00', saveField('stop'))); tr.appendChild(stop);
    const actions = document.createElement('td');
    const remove = document.createElement('button'); remove.type = 'button'; remove.className = 'position-action remove'; remove.textContent = 'Remove'; remove.addEventListener('click', () => { const next = savedPositions(); next.splice(index, 1); storePositions(next); renderPositions(); });
    actions.append(remove); tr.appendChild(actions); body.appendChild(tr);
  });
  const totalPl = totalValue - totalCost;
  const totalPercent = totalCost > 0 ? totalPl / totalCost * 100 : 0;
  document.querySelector('#positions-value').textContent = money(totalValue);
  document.querySelector('#positions-pl').textContent = `${totalPl >= 0 ? '+' : ''}${money(totalPl)}`;
  document.querySelector('#positions-percent').textContent = `${totalPercent >= 0 ? '+' : ''}${totalPercent.toFixed(2)}%`;
  ['#positions-pl', '#positions-percent'].forEach(selector => { const element = document.querySelector(selector); element.className = totalPl >= 0 ? 'position-profit' : 'position-loss'; });
}
document.querySelector('#add-position').addEventListener('click', () => { const rows = savedPositions(); rows.push({ ticker: '', shares: '', entry: '', current: '', stop: '' }); storePositions(rows); renderPositions(); document.querySelector('#positions-body tr:last-child input')?.focus(); });
renderPositions();
function presets() { try { return JSON.parse(localStorage.getItem('tradingBotPresets') || '{}'); } catch { return {}; } }
function refreshPresets(selected = '') {
  const saved = presets();
  presetSelect.innerHTML = '<option value="">Saved presets…</option>';
  Object.keys(saved).sort().forEach(name => { const option = document.createElement('option'); option.value = name; option.textContent = name; presetSelect.appendChild(option); });
  presetSelect.value = selected;
}
function applyPreset(saved) {
  Object.entries(saved).forEach(([name, val]) => { const control = form.elements[name]; if (!control) return; if (control.type === 'checkbox') control.checked = Boolean(val); else control.value = val; });
  form.elements.mode.dispatchEvent(new Event('change'));
  form.elements.settings_source.dispatchEvent(new Event('change'));
  initializeSymbols();
}

document.querySelector('#clock').textContent = new Date().toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
function updateMode() {
  modePill.textContent = form.elements.mode.value.replace('_', ' ').toUpperCase();
  const sweep = form.elements.mode.value === 'sweep';
  form.elements.sweep_capture.disabled = !sweep;
  document.querySelector('.sweep-capture').classList.toggle('disabled', !sweep);
}
form.elements.mode.addEventListener('change', updateMode);
updateMode();
function updateSettingsSource() {
  const manual = form.elements.settings_source.value === 'manual';
  document.querySelectorAll('.strategy-param').forEach(label => { label.classList.toggle('disabled', !manual); label.querySelector('input').disabled = !manual; });
  document.querySelector('#settings-note').textContent = manual
    ? 'Manual override: these values will be passed on the command line and applied according to your bot’s CLI behavior.'
    : 'Portfolio-safe: strategy flags will be omitted so each stock uses its configuration already stored in the bot.';
  renderSymbols();
}
form.elements.settings_source.addEventListener('change', updateSettingsSource);

function normalizeSymbol(value) {
  return value.toUpperCase().trim().replace(/_GOOGLEFINANCE_AUTOUPTODATE$/i, '').replace(/[^A-Z0-9._-]/g, '');
}
function syncSymbols() {
  form.elements.symbol_universe.value = symbolRows.map(row => row.symbol).join(',');
  form.elements.symbols.value = symbolRows.filter(row => row.enabled).map(row => row.symbol).join(',');
  const enabled = symbolRows.filter(row => row.enabled).length;
  document.querySelector('#symbol-count').textContent = `${enabled} enabled`;
}
function renderSymbols() {
  const body = document.querySelector('#symbol-rows');
  if (!body) return;
  body.innerHTML = '';
  const manual = form.elements.settings_source.value === 'manual';
  symbolRows.forEach((row, index) => {
    const tr = document.createElement('tr');
    const enabledCell = document.createElement('td'); const toggle = document.createElement('input'); toggle.type = 'checkbox'; toggle.checked = row.enabled; toggle.addEventListener('change', () => { symbolRows[index].enabled = toggle.checked; syncSymbols(); }); enabledCell.appendChild(toggle);
    const symbolCell = document.createElement('td'); symbolCell.className = 'symbol-name'; symbolCell.textContent = row.symbol;
    const statusCell = document.createElement('td'); statusCell.className = 'config-status'; statusCell.textContent = manual ? 'Manual override' : 'Uses bot internal config';
    const removeCell = document.createElement('td'); const remove = document.createElement('button'); remove.type = 'button'; remove.className = 'remove-symbol'; remove.textContent = 'Remove'; remove.addEventListener('click', () => { symbolRows.splice(index, 1); renderSymbols(); syncSymbols(); }); removeCell.appendChild(remove);
    [enabledCell, symbolCell, statusCell, removeCell].forEach(cell => tr.appendChild(cell)); body.appendChild(tr);
  });
  syncSymbols();
}
function initializeSymbols() {
  const universe = form.elements.symbol_universe.value.split(',').map(normalizeSymbol).filter(Boolean);
  const enabled = new Set(form.elements.symbols.value.split(',').map(normalizeSymbol).filter(Boolean));
  symbolRows = [...new Set(universe.length ? universe : [...enabled])].map(symbol => ({ symbol, enabled: enabled.has(symbol) }));
  renderSymbols();
}
document.querySelector('#add-symbol').addEventListener('click', () => { const symbol = normalizeSymbol(prompt('Ticker symbol:') || ''); if (!symbol) return; const existing = symbolRows.find(row => row.symbol === symbol); if (existing) existing.enabled = true; else symbolRows.push({ symbol, enabled: true }); renderSymbols(); });
document.querySelector('#select-all-symbols').addEventListener('click', () => { symbolRows.forEach(row => { row.enabled = true; }); renderSymbols(); });
document.querySelector('#clear-symbols').addEventListener('click', () => { symbolRows.forEach(row => { row.enabled = false; }); renderSymbols(); });
initializeSymbols();
updateSettingsSource();
document.querySelectorAll('[data-mode]').forEach(button => button.addEventListener('click', () => { form.elements.mode.value = button.dataset.mode; form.elements.mode.dispatchEvent(new Event('change')); document.querySelector('#runner').scrollIntoView({ behavior: 'smooth' }); }));
document.querySelectorAll('.nav-item').forEach(button => button.addEventListener('click', () => { document.querySelectorAll('.nav-item').forEach(item => item.classList.remove('active')); button.classList.add('active'); const target = button.dataset.view && document.querySelector(`#${button.dataset.view}`); if (target) target.scrollIntoView({ behavior: 'smooth' }); }));

document.querySelector('#preview').addEventListener('click', async () => { try { commandBox.textContent = (await jsonPost('/api/preview')).command; document.querySelector('.command').open = true; } catch (error) { commandBox.textContent = error.message; } });

refreshPresets();
document.querySelector('#load-preset').addEventListener('click', () => { const saved = presets()[presetSelect.value]; if (!saved) return alert('Choose a preset first.'); applyPreset(saved); });
document.querySelector('#save-preset').addEventListener('click', () => { const name = prompt('Name this preset:', presetSelect.value || '')?.trim(); if (!name) return; const saved = presets(); if (saved[name] && !confirm(`Update existing preset "${name}"?`)) return; saved[name] = payload(); localStorage.setItem('tradingBotPresets', JSON.stringify(saved)); refreshPresets(name); });
document.querySelector('#delete-preset').addEventListener('click', () => { const name = presetSelect.value; if (!name) return alert('Choose a preset first.'); if (!confirm(`Delete preset "${name}"?`)) return; const saved = presets(); delete saved[name]; localStorage.setItem('tradingBotPresets', JSON.stringify(saved)); refreshPresets(); });

document.querySelector('#export-gui-data').addEventListener('click', () => {
  const backup = { version: 1, exported_at: new Date().toISOString(), presets: presets(), positions: savedPositions() };
  const blob = new Blob([JSON.stringify(backup, null, 2)], { type: 'application/json' });
  const url = URL.createObjectURL(blob); const link = document.createElement('a');
  link.href = url; link.download = `trading_gui_backup_${new Date().toISOString().slice(0, 10)}.json`; link.click(); URL.revokeObjectURL(url);
});
const importFile = document.querySelector('#import-gui-file');
document.querySelector('#import-gui-data').addEventListener('click', () => importFile.click());
importFile.addEventListener('change', async () => {
  const file = importFile.files[0]; if (!file) return;
  try {
    const backup = JSON.parse(await file.text());
    if (!backup || typeof backup.presets !== 'object' || !Array.isArray(backup.positions)) throw new Error('This is not a valid Trading GUI backup file.');
    if (!confirm('Replace the presets and live positions in this browser with this backup?')) return;
    localStorage.setItem('tradingBotPresets', JSON.stringify(backup.presets)); storePositions(backup.positions); refreshPresets(); renderPositions(); alert('GUI data imported successfully.');
  } catch (error) { alert(error.message); } finally { importFile.value = ''; }
});

stopButton.addEventListener('click', async () => {
  if (!currentRunId || !confirm('Stop the active bot run?')) return;
  try {
    const response = await fetch(`/api/run/${currentRunId}/stop`, { method: 'POST' });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || 'Could not stop run');
    setStatus('Stopped', 'error'); stopButton.disabled = true;
  } catch (error) { alert(error.message); }
});

form.addEventListener('submit', async event => {
  event.preventDefault();
  if (!confirm('Run the command shown by this GUI?')) return;
  try {
    resetMetrics(); setStatus('Running', 'running');
    const result = await jsonPost('/api/run');
    currentRunId = result.run_id; stopButton.disabled = false; commandBox.textContent = result.command; consoleBox.textContent = 'Starting…';
    loadRunHistory();
    const timer = setInterval(async () => {
      try {
        const response = await fetch(`/api/run/${result.run_id}`); const run = await response.json();
        applyRunData(run);
        if (run.finished) { clearInterval(timer); currentRunId = null; stopButton.disabled = true; const stopped = run.output.includes('Run stopped by user'); setStatus(stopped ? 'Stopped' : 'Finished', stopped ? 'error' : 'finished'); loadRunHistory(); }
      } catch (error) { clearInterval(timer); currentRunId = null; stopButton.disabled = true; setStatus('Error', 'error'); consoleBox.textContent += `\n${error.message}`; }
    }, 750);
  } catch (error) { currentRunId = null; stopButton.disabled = true; setStatus('Error', 'error'); consoleBox.textContent = error.message; }
});

async function loadLatestRun() {
  try {
    const response = await fetch('/api/latest', { cache: 'no-store' });
    if (!response.ok) return;
    const run = await response.json();
    applyRunData(run);
    setStatus(run.finished ? 'Finished' : 'Previous Run', run.finished ? 'finished' : 'idle');
  } catch (_) { /* A previous run is optional. */ }
}

loadLatestRun();
loadRunHistory();

const dataForm = document.querySelector('#data-form');
const dataConsole = document.querySelector('#data-console');
const dataStatus = document.querySelector('#data-status');
const stopDataButton = document.querySelector('#stop-data');

function dataPayload(action) {
  const data = Object.fromEntries(new FormData(dataForm));
  data.action = action;
  data.one_trade = false;
  return data;
}

function setDataStatus(text, kind) {
  dataStatus.textContent = text.toUpperCase();
  dataStatus.className = `run-status ${kind}`;
}

function dataConsoleDisplayText(text) {
  const raw = String(text || '');
  if (document.querySelector('#data-console-view')?.value === 'full') return raw;
  const lines = raw
    .replace(/\x1B(?:[@-Z\\-_]|\[[0-?]*[ -\/]*[@-~])/g, '')
    .replace(/_GoogleFinance_AutoUpToDate/gi, '')
    .replace(/[A-Z]:[\\\/][^\r\n]*?Trading_Bot_Officiel[\\\/]/gi, '')
    .split(/\r?\n/);
  let insideActiveConfiguration = false;
  const visible = lines.filter(line => {
    if (/ACTIVE CONFIGURATION/i.test(line)) { insideActiveConfiguration = true; return false; }
    if (insideActiveConfiguration) {
      if (/^\s*=+\s*$/.test(line)) insideActiveConfiguration = false;
      return false;
    }
    return !/^\s*-?\d+(?:\.\d+)?\s*$/.test(line) &&
      !/^\s*[-=]{3,}\s*$/.test(line) &&
      !/^\s*🔍/.test(line) &&
      !/^\s*\[(?:BOOT|FCX_VOL|EARLY ENV|DEBUG PARAMS|STORAGE)\]/i.test(line) &&
      !/^\s*\[CONFIG\]\s+Start equity/i.test(line) &&
      !/:\d+: warning: (?:already initialized constant|previous definition)/i.test(line) &&
      !/^\s*\[BOT_METRICS\]/i.test(line) &&
      !/^\s*\[REGIME\]\s+Benchmark\s+VXX\s+missing/i.test(line) &&
      !/^\s*\[VIXY(?:\s+FAST)?\s+PANIC\]/i.test(line) &&
      !/^\s*\[REASON\]/i.test(line) &&
      !/^\s*(?:BUY|SELL)\s+\S+\s+\d{4}-\d{2}-\d{2}T/i.test(line) &&
      !/^\s*\[(?:SAVED|CLONED|WITH_BUYS)\]/i.test(line) &&
      !/^\s*🧹\s+Deleted old multi-signal/i.test(line) &&
      !/^\s*✅\s+Deduplicated\b/i.test(line);
  });
  return visible.join('\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function renderDataRows(rows) {
  const body = document.querySelector('#data-rows');
  body.innerHTML = '';
  if (!rows.length) { body.innerHTML = '<tr class="empty"><td colspan="5">No symbols were checked.</td></tr>'; return; }
  rows.forEach(row => {
    const tr = document.createElement('tr');
    [row.symbol, row.first_date || '—', row.last_date || '—', String(row.rows || 0), row.status].forEach((value, index) => {
      const td = document.createElement('td'); td.textContent = value;
      if (index === 4) { td.className = row.status === 'Available' ? 'data-good' : 'data-problem'; if (row.detail) td.title = row.detail; }
      tr.appendChild(td);
    });
    body.appendChild(tr);
  });
}

async function checkDataStatus(updateBadge = true) {
  try {
    if (updateBadge) setDataStatus('Checking', 'running');
    const response = await fetch('/api/data/status', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(dataPayload('verify')) });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || 'Could not inspect data');
    renderDataRows(result.rows); if (updateBadge) setDataStatus('Checked', 'finished');
  } catch (error) { if (updateBadge) setDataStatus('Error', 'error'); dataConsole.textContent += `\n${error.message}`; }
}

async function startDataWorkflow(action) {
  if (currentDataJobId) return alert('A data workflow is already running.');
  const description = action === 'update_run' ? 'update the selected data and then run the bot' : 'update the selected market data';
  if (!confirm(`Ready to ${description}?`)) return;
  try {
    setDataStatus('Starting', 'running'); currentDataRawOutput = 'Starting…'; dataConsole.textContent = currentDataRawOutput;
    const response = await fetch('/api/data/run', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(dataPayload(action)) });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || 'Could not start data workflow');
    currentDataJobId = result.job_id; stopDataButton.disabled = false;
    const timer = setInterval(async () => {
      try {
        const poll = await fetch(`/api/data/run/${result.job_id}`, { cache: 'no-store' });
        const job = await poll.json();
        if (!poll.ok) throw new Error(job.error || 'Could not read data workflow');
        currentDataRawOutput = job.output; dataConsole.textContent = dataConsoleDisplayText(currentDataRawOutput); dataConsole.scrollTop = dataConsole.scrollHeight;
        setDataStatus(job.finished ? (job.success ? 'Finished' : 'Failed') : (job.step || 'Running'), job.finished ? (job.success ? 'finished' : 'error') : 'running');
        if (job.finished) { clearInterval(timer); currentDataJobId = null; stopDataButton.disabled = true; await checkDataStatus(false); setDataStatus(job.success ? 'Finished' : 'Failed', job.success ? 'finished' : 'error'); }
      } catch (error) { clearInterval(timer); currentDataJobId = null; stopDataButton.disabled = true; setDataStatus('Error', 'error'); dataConsole.textContent += `\n${error.message}`; }
    }, 750);
  } catch (error) { currentDataJobId = null; stopDataButton.disabled = true; setDataStatus('Error', 'error'); dataConsole.textContent = error.message; }
}

document.querySelector('#check-data').addEventListener('click', checkDataStatus);
document.querySelector('#data-console-view').addEventListener('change', () => { dataConsole.textContent = dataConsoleDisplayText(currentDataRawOutput); dataConsole.scrollTop = dataConsole.scrollHeight; });
document.querySelector('#update-data').addEventListener('click', () => startDataWorkflow('update'));
document.querySelector('#update-run').addEventListener('click', () => startDataWorkflow('update_run'));
stopDataButton.addEventListener('click', async () => {
  if (!currentDataJobId || !confirm('Stop the active data workflow?')) return;
  try {
    const response = await fetch(`/api/data/run/${currentDataJobId}/stop`, { method: 'POST' });
    const result = await response.json(); if (!response.ok) throw new Error(result.error || 'Could not stop workflow');
    setDataStatus('Stopping', 'error');
  } catch (error) { alert(error.message); }
});
