"use strict";

/* getOracle dashboard — renders the sanitized stats.json into the
   "Field journal" UI. Single fetch on load; the page meta-refreshes. */

const STATS_URL = 'stats.json';

const REDUCED = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

/* ── helpers ─────────────────────────────────────────────────── */

function parseUTC(s) {
  if (!s) return null;
  const stamp = s.replace(' ', 'T');
  const d = new Date(/[zZ]|[+-]\d{2}:?\d{2}$/.test(stamp) ? stamp : stamp + 'Z');
  return isNaN(d) ? null : d;
}
const fmtDate  = d => d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
const fmtClock = d => d.toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit', hour12: false });
const fmtStamp = d => d ? `${fmtDate(d)}, ${fmtClock(d)}` : '—';
const fmtDow   = d => d.toLocaleDateString('en-US', { weekday: 'short' });

function fmtDuration(seconds) {
  if (!seconds || seconds < 0) return '0m';
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

function relTime(d) {
  if (!d) return '—';
  const s = Math.max(0, Math.floor((Date.now() - d.getTime()) / 1000));
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s ago`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m ago`;
}

function ordinal(n) {
  const words = ['zero','one','two','three','four','five','six','seven','eight','nine','ten',
                 'eleven','twelve','thirteen','fourteen','fifteen','sixteen','seventeen',
                 'eighteen','nineteen','twenty'];
  return words[n] || String(n);
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function countUp(node, target, format) {
  if (REDUCED || !(target > 0)) { node.innerHTML = format(target); return; }
  const dur = 900;
  const start = performance.now();
  (function frame(now) {
    const t = Math.min(1, (now - start) / dur);
    const eased = 1 - Math.pow(1 - t, 3);
    node.innerHTML = format(target * eased);
    if (t < 1) requestAnimationFrame(frame);
  })(performance.now());
}

/* ── hero ────────────────────────────────────────────────────── */

let lastAttemptDate = null;

function renderHero(stats) {
  const created = stats.status === 'instance_created';
  document.body.className = created ? 'state-created' : 'state-hunting';

  const eyebrow = document.getElementById('eyebrow-state');
  const dayWord = document.getElementById('hero-day');
  const lede    = document.getElementById('hero-lede');

  // Inclusive calendar-day count from first_attempt → today in the viewer's
  // local timezone. Partial-run days still count as a full day; this matches
  // the "we're on day N" mental model rather than active-hunting-time/86400
  // (which would drop a day every time downtime trims the running total).
  const watchDays = (() => {
    const first = parseUTC(stats.first_attempt);
    if (!first) return 1;
    const startLocal = new Date(first.getFullYear(), first.getMonth(), first.getDate());
    const now = new Date();
    const todayLocal = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    return Math.max(1, Math.floor((todayLocal - startLocal) / 86400000) + 1);
  })();

  if (created) {
    eyebrow.textContent = 'over.';
    dayWord.textContent = 'Capacity';
    document.querySelector('.hero-title .accent').textContent = 'acquired.';
    lede.innerHTML = 'An instance was provisioned. Check the <strong>INSTANCE_CREATED</strong> marker on the host for its public IP, then SSH in with your private key.';
  } else {
    eyebrow.textContent = 'listening…';
    const ord = ordinal(watchDays);
    dayWord.textContent = `Day ${ord.charAt(0).toUpperCase() + ord.slice(1)}`;
    lede.innerHTML = `No free ARM capacity in <strong>eu-stockholm-1</strong> yet. The watch retries on a 60-second cadence and stops the moment Oracle opens a slot.`;
  }

  const t = stats.totals;
  const attemptsEl = document.getElementById('stat-attempts');
  const watchEl    = document.getElementById('stat-watch');
  const rateEl     = document.getElementById('stat-rate');
  const uptimeEl   = document.getElementById('stat-uptime');

  countUp(attemptsEl, t.attempts, v => Math.round(v).toLocaleString());
  countUp(watchEl, stats.hunting_duration_seconds, v => {
    const h = Math.floor(v / 3600);
    const m = Math.floor((v % 3600) / 60);
    return `${h}<span class="unit">h</span> ${m}<span class="unit">m</span>`;
  });

  const perHour = stats.hunting_duration_seconds > 0
    ? Math.round(t.attempts / (stats.hunting_duration_seconds / 3600))
    : 0;
  countUp(rateEl, perHour, v => Math.round(v).toString());

  const total = stats.hunting_duration_seconds;
  const up = Math.max(0, total - (t.downtime_seconds || 0));
  const uptimePct = total > 0 ? (up / total) * 100 : 100;
  countUp(uptimeEl, uptimePct, v => `${v.toFixed(1)}<span class="unit">%</span>`);

  lastAttemptDate = parseUTC(stats.last_attempt);
  document.getElementById('last-rel').textContent = relTime(lastAttemptDate);
  document.getElementById('vol').textContent = `Vol. ${toRoman(watchDays)}`;
}

function tickLastRel() {
  const node = document.getElementById('last-rel');
  if (node && lastAttemptDate) node.textContent = relTime(lastAttemptDate);
}

function toRoman(num) {
  const map = [['X',10],['IX',9],['V',5],['IV',4],['I',1]];
  let s = '';
  for (const [r, v] of map) while (num >= v) { s += r; num -= v; }
  return s || 'I';
}

/* ── heatmap ─────────────────────────────────────────────────── */

function renderHeatmap(stats) {
  const buckets = stats.timeline || [];
  const note = document.getElementById('heatmap-note');
  const grid = document.getElementById('heatmap');

  if (!buckets.length) {
    note.textContent = 'no signals yet';
    return;
  }

  // Re-bin upstream UTC hourly buckets into the viewer's local timezone so
  // the row dates, column hour labels and "now" cell all match the wall
  // clock. At integer offsets (e.g. CEST = UTC+2) each UTC hour maps 1:1
  // to a local hour; at fractional offsets (IST = UTC+5:30) we'd want
  // sub-hour resampling, but no realistic viewer hits that here.
  const dayKeyOf = d =>
    `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

  const byLocalDay = new Map();   // "YYYY-MM-DD" (local) → 24-slot array
  let peak = 0;
  for (const b of buckets) {
    const utc = parseUTC(b.hour);
    if (!utc) continue;
    const dk = dayKeyOf(utc);
    const lh = utc.getHours();
    if (!byLocalDay.has(dk)) byLocalDay.set(dk, new Array(24).fill(null));
    const row = byLocalDay.get(dk);
    row[lh] = (row[lh] || 0) + b.attempts;
    if (row[lh] > peak) peak = row[lh];
  }

  const dayKeys = Array.from(byLocalDay.keys()).sort();
  const days = dayKeys.slice(-7);

  const gapWindows = (stats.gaps || [])
    .map(g => [parseUTC(g.from), parseUTC(g.to)])
    .filter(([a, b]) => a && b);

  const now = parseUTC(stats.generated_at) || new Date();

  // header row: blank corner + 0..23 (local hours)
  grid.appendChild(el('div', 'hm-hdr day', ''));
  for (let h = 0; h < 24; h++) {
    const hdr = el('div', `hm-hdr h-${h}`, h.toString().padStart(2, '0'));
    grid.appendChild(hdr);
  }

  // one row per local day
  for (const dayKey of days) {
    const [y, m, d] = dayKey.split('-').map(Number);
    const dayDate = new Date(y, m - 1, d);
    const label = el('div', 'hm-row-label');
    label.appendChild(document.createTextNode(fmtDate(dayDate)));
    const dow = el('span', 'dow', fmtDow(dayDate));
    label.appendChild(dow);
    grid.appendChild(label);

    const hours = byLocalDay.get(dayKey) || new Array(24).fill(null);
    for (let h = 0; h < 24; h++) {
      const attempts = hours[h];
      const hourStart = new Date(y, m - 1, d, h);
      const hourEnd = new Date(y, m - 1, d, h + 1);

      const cell = el('div', 'hm-cell');

      if (hourStart > now) {
        cell.classList.add('future');
        grid.appendChild(cell);
        continue;
      }

      const inGap = gapWindows.some(([a, b]) => a < hourEnd && b > hourStart);
      if (inGap && (attempts == null || attempts < 5)) {
        cell.classList.add('gap');
      } else if (attempts != null) {
        const ratio = peak > 0 ? attempts / peak : 0;
        let lvl = 0;
        if (ratio > 0.0)  lvl = 1;
        if (ratio > 0.25) lvl = 2;
        if (ratio > 0.5)  lvl = 3;
        if (ratio > 0.85) lvl = 4;
        if (lvl > 0) cell.classList.add(`lvl-${lvl}`);
      }

      if (now >= hourStart && now < hourEnd) cell.classList.add('now');

      const dispAttempts = attempts != null ? attempts : 0;
      cell.dataset.label = `${fmtDate(hourStart)} · ${String(h).padStart(2, '0')}:00 — ${dispAttempts}${inGap ? ' (offline)' : ''}`;
      grid.appendChild(cell);
    }
  }

  note.textContent = `${days.length} days · peak ${peak}/hr`;
}

/* ── tally lists ─────────────────────────────────────────────── */

function kvRow(key, value, opts = {}) {
  const li = document.createElement('li');
  const k = el('span', 'k', key);
  li.appendChild(k);
  if (opts.code) li.appendChild(el('span', `code c${opts.code}`, opts.code));
  const v = el('span', 'v');
  v.innerHTML = value;
  li.appendChild(v);
  return li;
}

function renderTally(stats) {
  const t = stats.totals;
  const rej = document.getElementById('rejections');
  rej.appendChild(kvRow('rate-limited', t.rate_limited_429.toLocaleString(), { code: '429' }));
  rej.appendChild(kvRow('out of capacity', t.out_of_capacity_500.toLocaleString(), { code: '500' }));
  if (t.other > 0) rej.appendChild(kvRow('other responses', t.other.toLocaleString()));

  const intr = document.getElementById('interruptions');
  intr.appendChild(kvRow('offline gaps', t.gaps.toLocaleString()));
  const downH = Math.floor(t.downtime_seconds / 3600);
  const downM = Math.floor((t.downtime_seconds % 3600) / 60);
  intr.appendChild(kvRow('total downtime', `${downH}<span class="unit">h</span> ${downM}<span class="unit">m</span>`));
  intr.appendChild(kvRow('connection resets', t.crashes.toLocaleString()));
}

/* ── log + gaps ──────────────────────────────────────────────── */

const LOG_RE = /^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})\s+(\d+)\s*(.*)$/;

function renderLog(stats) {
  const container = document.getElementById('log-tail');
  if (!stats.log_tail.length) {
    container.appendChild(el('li', 'empty', 'no attempts logged yet'));
    return;
  }
  for (const line of stats.log_tail.slice().reverse()) {
    const li = document.createElement('li');
    const m = LOG_RE.exec(line);
    if (!m) {
      li.appendChild(el('span', 'msg', line));
      container.appendChild(li);
      continue;
    }
    const [, date, clock, status, message] = m;
    // log line clocks are UTC from the VM publisher — render in the viewer's locale
    const local = parseUTC(`${date}T${clock}`);
    const cls = status === '429' ? 'chip chip-429'
              : status === '500' ? 'chip chip-500'
              : 'chip chip-other';
    li.appendChild(el('span', 'ts', local ? fmtClock(local) : clock));
    li.appendChild(el('span', cls, status));
    li.appendChild(el('span', 'msg', message || '—'));
    container.appendChild(li);
  }
}

function renderGaps(stats) {
  const container = document.getElementById('gaps');
  if (!stats.gaps.length) {
    container.appendChild(el('li', 'empty', 'none — the watch has held steady'));
    return;
  }
  for (const gap of stats.gaps.slice().reverse()) {
    const from = parseUTC(gap.from);
    const to = parseUTC(gap.to);
    const li = document.createElement('li');
    li.appendChild(el('span', 'ts', from ? fmtStamp(from) : gap.from));
    li.appendChild(el('span', 'gap-arrow', '→'));
    const sameDay = from && to && from.toDateString() === to.toDateString();
    li.appendChild(el('span', 'gap-route',
      to ? (sameDay ? fmtClock(to) : fmtStamp(to)) : gap.to));
    li.appendChild(el('span', 'gap-dur', fmtDuration(gap.duration_seconds)));
    container.appendChild(li);
  }
}

/* ── boot ────────────────────────────────────────────────────── */

async function main() {
  try {
    const res = await fetch(STATS_URL, { cache: 'no-store' });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const stats = await res.json();
    if (!stats || !stats.totals || !Array.isArray(stats.timeline) ||
        !Array.isArray(stats.gaps) || !Array.isArray(stats.log_tail)) {
      throw new Error('stats.json shape mismatch');
    }
    renderHero(stats);
    renderHeatmap(stats);
    renderTally(stats);
    renderLog(stats);
    renderGaps(stats);
    const gen = parseUTC(stats.generated_at);
    document.getElementById('updated').textContent =
      gen ? `updated ${fmtClock(gen)}` : 'updated —';
    setInterval(tickLastRel, 1000);
  } catch (err) {
    console.error('dashboard fetch failed:', err);
    document.body.className = 'state-error';
    document.getElementById('eyebrow-state').textContent = 'lost.';
    document.getElementById('hero-day').textContent = 'Signal';
    document.querySelector('.hero-title .accent').textContent = 'dropped.';
    document.getElementById('hero-lede').textContent =
      'stats.json could not be loaded — the watch may be mid-publish. This page retries automatically.';
  }
}

main();
