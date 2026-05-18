"use strict";

/* getOracle dashboard — renders the sanitized stats.json into the
   "Observatory watch" UI. Single fetch on load; the page meta-refreshes. */

const PLOT_HEIGHT = 178;
const REDUCED = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

// Round a per-tick step up to a clean 1/2/5 × 10ⁿ value (min 1) so axis
// labels read as whole numbers like 0, 20, 40 rather than 0, 19.6, 39.3.
function niceStep(maxValue, targetTicks) {
  const raw = maxValue / targetTicks;
  const pow = Math.pow(10, Math.floor(Math.log10(raw)));
  const n = raw / pow;
  let step;
  if (n <= 1) step = 1;
  else if (n <= 2) step = 2;
  else if (n <= 5) step = 5;
  else step = 10;
  return Math.max(1, step * pow);
}

function fmtDuration(seconds) {
  if (!seconds || seconds < 0) return "0m";
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  return h > 0 ? `${h}h ${m}m` : `${m}m`;
}

// Parse a "YYYY-MM-DDTHH:MM[:SS]" or "YYYY-MM-DD HH:MM:SS" stamp as UTC.
// The publisher (VM, UTC) emits naive stamps; we treat them as UTC so the
// browser renders them in the viewer's local clock via toLocale*.
function parseUTC(s) {
  if (!s) return null;
  const stamp = s.replace(" ", "T");
  const d = new Date(/[zZ]|[+-]\d{2}:?\d{2}$/.test(stamp) ? stamp : stamp + "Z");
  return isNaN(d) ? null : d;
}

function fmtDate(d) {
  return d.toLocaleDateString("en-US", { month: "short", day: "numeric" });
}
function fmtClock(d) {
  return d.toLocaleTimeString("en-US", { hour: "2-digit", minute: "2-digit", hour12: false });
}
function fmtStamp(d) {
  return d ? `${fmtDate(d)}, ${fmtClock(d)}` : "—";
}

function relTime(d) {
  if (!d) return "—";
  const s = Math.max(0, Math.floor((Date.now() - d.getTime()) / 1000));
  if (s < 60) return `${s}s ago`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${s % 60}s ago`;
  const h = Math.floor(m / 60);
  return `${h}h ${m % 60}m ago`;
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// Animate a number from 0 to target, formatting each frame.
function countUp(node, target, format) {
  if (REDUCED || !(target > 0)) { node.textContent = format(target); return; }
  const dur = 900;
  const start = performance.now();
  (function frame(now) {
    const t = Math.min(1, (now - start) / dur);
    const eased = 1 - Math.pow(1 - t, 3);
    node.textContent = format(target * eased);
    if (t < 1) requestAnimationFrame(frame);
  })(performance.now());
}

/* ---- hero ---------------------------------------------------------------- */

let lastAttemptDate = null;

function renderHero(stats) {
  const word = document.getElementById("state-word");
  const sub = document.getElementById("hero-sub");
  const created = stats.status === "instance_created";

  document.body.className = created ? "state-created" : "state-hunting";

  if (created) {
    word.textContent = "capacity acquired";
    sub.textContent =
      "An instance was provisioned. Check the INSTANCE_CREATED marker on the " +
      "host for its public IP, then SSH in with your private key.";
    const vpu = el("span", "vpu",
      stats.vpu_bumped ? "boot volume bumped to 120 VPU ✓" : "VPU bump pending");
    sub.appendChild(vpu);
  } else {
    word.textContent = "hunting";
    sub.textContent =
      "No free ARM capacity in the region yet. The hunt keeps retrying — " +
      "and stops the moment Oracle opens a slot.";
  }

  const t = stats.totals;
  countUp(document.getElementById("m-attempts"), t.attempts, (v) => String(Math.round(v)));
  countUp(document.getElementById("m-watch"), stats.hunting_duration_seconds,
    (v) => fmtDuration(Math.round(v)));

  const perHour = stats.hunting_duration_seconds > 0
    ? Math.round(t.attempts / (stats.hunting_duration_seconds / 3600))
    : 0;

  lastAttemptDate = parseUTC(stats.last_attempt);
  const firstDate = parseUTC(stats.first_attempt);

  const readout = document.getElementById("hero-readout");
  readout.textContent = "";
  readout.append("last signal ");
  const rel = el("b", null, relTime(lastAttemptDate));
  rel.id = "rel";
  readout.append(rel);
  readout.append(sepSpan(), `${perHour} attempts / hour average`);
  if (firstDate) readout.append(sepSpan(), `watch began ${fmtStamp(firstDate)}`);
}

function sepSpan() { return el("span", "sep", "·"); }

function tickRel() {
  const rel = document.getElementById("rel");
  if (rel && lastAttemptDate) rel.textContent = relTime(lastAttemptDate);
}

/* ---- chart --------------------------------------------------------------- */

function renderChart(stats) {
  const buckets = stats.timeline;
  const note = document.getElementById("chart-note");
  if (!buckets.length) {
    note.textContent = "no signals logged yet";
    return;
  }

  const plot = document.getElementById("timeline");
  const grid = document.getElementById("chart-grid");
  const gapsLayer = document.getElementById("chart-gaps");
  const yAxis = document.getElementById("chart-yaxis");
  const xAxis = document.getElementById("chart-xaxis");

  // Snap the scale to a round max so bars line up with the gridlines.
  const rawMax = Math.max(1, ...buckets.map((b) => b.attempts));
  const step = niceStep(rawMax, 4);
  const axisMax = Math.ceil(rawMax / step) * step;

  // Y-axis: a tick label + gridline at each step from 0 to axisMax.
  for (let v = 0; v <= axisMax; v += step) {
    const offset = `${(v / axisMax) * PLOT_HEIGHT}px`;
    const tick = el("div", "tick", String(v));
    tick.style.bottom = offset;
    yAxis.appendChild(tick);
    const gridline = el("div", v === 0 ? "gridline base" : "gridline");
    gridline.style.bottom = offset;
    grid.appendChild(gridline);
  }

  // Offline-gap windows, used to shade the hours they overlap.
  const gapWindows = (stats.gaps || [])
    .map((g) => [parseUTC(g.from), parseUTC(g.to)])
    .filter(([a, b]) => a && b);

  buckets.forEach((bucket, i) => {
    const start = parseUTC(bucket.hour);
    const end = start ? new Date(start.getTime() + 3600 * 1000) : null;
    const inGap = start && gapWindows.some(([a, b]) => a < end && b > start);

    const gapcell = el("div", inGap ? "gapcell is-gap" : "gapcell");
    gapsLayer.appendChild(gapcell);

    const bar = el("div", bucket.attempts === 0 ? "bar empty" : "bar");
    bar.style.height = `${Math.max(2, (bucket.attempts / axisMax) * PLOT_HEIGHT)}px`;
    bar.style.animationDelay = `${Math.min(i * 9, 420)}ms`;
    bar.dataset.label = `${start ? fmtClock(start) : bucket.hour} · ${bucket.attempts}`;
    plot.appendChild(bar);
  });

  // X-axis: one cell per bar; a sparse HH:MM label, and a date marker at
  // each midnight so a chart spanning multiple days stays readable.
  const stride = Math.max(1, Math.ceil(buckets.length / 8));
  buckets.forEach((bucket, i) => {
    const cell = el("div", "xcell");
    const isMidnight = bucket.hour.slice(11, 13) === "00";
    if (isMidnight || i === 0) {
      const date = parseUTC(bucket.hour);
      cell.appendChild(el("span", "xlabel day", date ? fmtDate(date) : bucket.hour));
    } else if (i % stride === 0) {
      cell.appendChild(el("span", "xlabel", bucket.hour.slice(11, 16)));
    }
    xAxis.appendChild(cell);
  });

  const peak = Math.max(...buckets.map((b) => b.attempts));
  note.textContent = `${buckets.length}h watched · peak ${peak}/hr`;
}

/* ---- stat lists ---------------------------------------------------------- */

function statRow(num, desc, code, codeClass) {
  const li = document.createElement("li");
  if (code !== undefined) li.appendChild(el("span", codeClass || "stat-code", code));
  li.appendChild(el("span", "stat-num", String(num)));
  li.appendChild(el("span", "stat-desc", desc));
  return li;
}

function renderStats(stats) {
  const t = stats.totals;

  const rej = document.getElementById("rejections");
  rej.appendChild(statRow(t.rate_limited_429, "rate-limited", "429"));
  rej.appendChild(statRow(t.out_of_capacity_500, "out of capacity", "500"));
  if (t.other > 0) rej.appendChild(statRow(t.other, "other responses", "—", "stat-code chip-other"));

  const intr = document.getElementById("interruptions");
  intr.appendChild(statRow(t.gaps, "offline gaps"));
  intr.appendChild(statRow(fmtDuration(t.downtime_seconds), "total downtime"));
  intr.appendChild(statRow(t.crashes, "connection resets"));
}

/* ---- log + gaps ---------------------------------------------------------- */

const LOG_RE = /^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})\s+(\d+)\s*(.*)$/;

function renderLog(stats) {
  const container = document.getElementById("log-tail");
  if (!stats.log_tail.length) {
    container.appendChild(el("li", "empty", "no attempts logged yet"));
    return;
  }
  // newest first reads better than the chronological tail
  for (const line of stats.log_tail.slice().reverse()) {
    const li = document.createElement("li");
    const m = LOG_RE.exec(line);
    if (!m) {
      li.appendChild(el("span", "log-raw", line));
      container.appendChild(li);
      continue;
    }
    const [, , clock, status, message] = m;
    li.appendChild(el("span", "log-ts", clock));
    const code = status === "0" ? "·" : status;
    const cls = status === "429" ? "chip chip-429"
      : status === "500" ? "chip chip-500"
      : "chip chip-other";
    li.appendChild(el("span", cls, code));
    li.appendChild(el("span", "log-msg", message || "—"));
    container.appendChild(li);
  }
}

function renderGaps(stats) {
  const container = document.getElementById("gaps");
  if (!stats.gaps.length) {
    container.appendChild(el("li", "empty", "none — the watch has held steady"));
    return;
  }
  for (const gap of stats.gaps.slice().reverse()) {
    const from = parseUTC(gap.from);
    const to = parseUTC(gap.to);
    const li = document.createElement("li");
    li.appendChild(el("span", "log-ts", from ? fmtStamp(from) : gap.from));
    li.appendChild(el("span", "gap-arrow", "→"));
    const sameDay = from && to && from.toDateString() === to.toDateString();
    li.appendChild(el("span", "gap-route",
      to ? (sameDay ? fmtClock(to) : fmtStamp(to)) : gap.to));
    li.appendChild(el("span", "gap-dur", fmtDuration(gap.duration_seconds)));
    container.appendChild(li);
  }
}

/* ---- boot ---------------------------------------------------------------- */

async function main() {
  try {
    const res = await fetch("stats.json", { cache: "no-store" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const stats = await res.json();
    if (!stats || !stats.totals || !Array.isArray(stats.timeline) ||
        !Array.isArray(stats.gaps) || !Array.isArray(stats.log_tail)) {
      throw new Error("stats.json shape mismatch");
    }

    renderHero(stats);
    renderChart(stats);
    renderStats(stats);
    renderLog(stats);
    renderGaps(stats);

    document.getElementById("updated").textContent =
      `updated ${fmtStamp(parseUTC(stats.generated_at))} · refreshes every 3m`;

    setInterval(tickRel, 1000);
  } catch (err) {
    console.error("dashboard fetch failed:", err);
    document.body.className = "state-error";
    document.getElementById("state-word").textContent = "signal lost";
    document.getElementById("hero-sub").textContent =
      "stats.json could not be loaded — the watch may be mid-publish. " +
      "This page retries automatically.";
    document.getElementById("hero-readout").textContent = "";
  }
}

main();
