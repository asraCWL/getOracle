"use strict";

const PLOT_HEIGHT = 120;

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

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function renderStatus(stats) {
  const line = document.getElementById("status-line");
  if (stats.status === "instance_created") {
    line.className = "status-line created";
    line.textContent = "✦ INSTANCE CREATED";
  } else {
    line.className = "status-line";
    line.textContent = `● HUNTING — ${fmtDuration(stats.hunting_duration_seconds)} active`;
  }
}

function renderCards(stats) {
  const t = stats.totals;
  const perHour = stats.hunting_duration_seconds > 0
    ? Math.round(t.attempts / (stats.hunting_duration_seconds / 3600))
    : 0;
  const cards = [
    ["attempts", t.attempts],
    ["429 rate-limited", t.rate_limited_429],
    ["500 out-of-capacity", t.out_of_capacity_500],
    ["crashes", t.crashes],
    ["offline gaps", t.gaps],
    ["downtime", fmtDuration(t.downtime_seconds)],
    ["last attempt", stats.last_attempt ? stats.last_attempt.slice(11) : "—"],
    ["attempts / hour", perHour],
  ];
  const container = document.getElementById("cards");
  for (const [label, value] of cards) {
    const card = el("div", "card");
    card.appendChild(el("div", "value", String(value)));
    card.appendChild(el("div", "label", label));
    container.appendChild(card);
  }
}

function renderTimeline(stats) {
  const plot = document.getElementById("timeline");
  const grid = document.getElementById("chart-grid");
  const yAxis = document.getElementById("chart-yaxis");
  const xAxis = document.getElementById("chart-xaxis");
  const buckets = stats.timeline;

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
    const gridline = el("div", "gridline");
    gridline.style.bottom = offset;
    grid.appendChild(gridline);
  }

  // Bars, scaled to axisMax so their heights match the gridlines.
  for (const bucket of buckets) {
    const bar = el("div", bucket.attempts === 0 ? "bar empty" : "bar");
    bar.style.height = `${Math.max(2, (bucket.attempts / axisMax) * PLOT_HEIGHT)}px`;
    bar.title = `${bucket.hour} — ${bucket.attempts} attempts`;
    plot.appendChild(bar);
  }

  // X-axis: one cell per bar; a sparse HH:00 label, and a date marker at
  // each midnight so a chart spanning multiple days stays readable.
  const stride = Math.max(1, Math.ceil(buckets.length / 8));
  buckets.forEach((bucket, i) => {
    const cell = el("div", "xcell");
    const isMidnight = bucket.hour.slice(11, 13) === "00";
    if (isMidnight || i === 0) {
      const date = new Date(bucket.hour);
      cell.appendChild(el("span", "xlabel day",
        date.toLocaleDateString("en-US", { month: "short", day: "numeric" })));
    } else if (i % stride === 0) {
      cell.appendChild(el("span", "xlabel", bucket.hour.slice(11, 16)));
    }
    xAxis.appendChild(cell);
  });
}

function renderGaps(stats) {
  const container = document.getElementById("gaps");
  if (!stats.gaps.length) {
    container.appendChild(el("li", null, "none"));
    return;
  }
  for (const gap of stats.gaps) {
    container.appendChild(
      el("li", null, `${gap.from} → ${gap.to}  (${fmtDuration(gap.duration_seconds)})`)
    );
  }
}

function renderLogTail(stats) {
  const container = document.getElementById("log-tail");
  if (!stats.log_tail.length) {
    container.appendChild(el("li", null, "no attempts logged yet"));
    return;
  }
  for (const line of stats.log_tail) {
    container.appendChild(el("li", null, line));
  }
}

async function main() {
  try {
    const res = await fetch("stats.json", { cache: "no-store" });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const stats = await res.json();
    if (!stats || !stats.totals || !Array.isArray(stats.timeline) ||
        !Array.isArray(stats.gaps) || !Array.isArray(stats.log_tail)) {
      throw new Error("stats.json shape mismatch");
    }
    renderStatus(stats);
    renderCards(stats);
    renderTimeline(stats);
    renderGaps(stats);
    renderLogTail(stats);
    document.getElementById("footer-caption").textContent =
      `updated ${stats.generated_at} · auto 15m`;
  } catch (err) {
    console.error("dashboard fetch failed:", err);
    document.getElementById("status-line").textContent = "stats unavailable";
  }
}

main();
