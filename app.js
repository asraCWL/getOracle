"use strict";

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
  const container = document.getElementById("timeline");
  const max = Math.max(1, ...stats.timeline.map((b) => b.attempts));
  for (const bucket of stats.timeline) {
    const bar = el("div", bucket.attempts === 0 ? "bar empty" : "bar");
    bar.style.height = `${Math.max(2, (bucket.attempts / max) * 120)}px`;
    bar.title = `${bucket.hour} — ${bucket.attempts} attempts`;
    container.appendChild(bar);
  }
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
    if (!stats || !stats.totals || !Array.isArray(stats.timeline)) {
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
