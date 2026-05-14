# Oracle VPS Capacity-Watch Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a GitHub Pages dashboard that shows the Oracle VPS hunt's live stats — counts, hourly timeline, offline gaps, recent activity — auto-published every 15 minutes.

**Architecture:** A pure-stdlib Python generator parses the hunt logs into a sanitized `stats.json`. Static HTML/CSS/JS renders it in the browser. A zsh publish script regenerates the stats, syncs both into a `gh-pages` git worktree, and pushes; a launchd job runs it every 15 minutes. `vps-ctl.sh` gains a `publish` command and manages the new launchd agent alongside the hunt agent.

**Tech Stack:** Python 3 (standard library only), vanilla HTML/CSS/JS, zsh, git worktrees, macOS launchd, GitHub Pages, the `gh` CLI.

**Spec:** [docs/superpowers/specs/2026-05-14-oracle-vps-dashboard-design.md](../specs/2026-05-14-oracle-vps-dashboard-design.md)

---

## File Structure

**Created:**
- `dashboard/generate_stats.py` — parses `launch_instance.log` + `stderr.log` + marker files into a sanitized stats dict; writes `stats.json`. Pure functions, unit-tested.
- `dashboard/index.html` — page skeleton; empty containers filled by `app.js`.
- `dashboard/style.css` — Axiom "Dark Matter Console" styling (layered dark surfaces, `#DA5C2C` accent).
- `dashboard/app.js` — fetches `stats.json`, renders status / cards / timeline / gaps / log tail.
- `publish_dashboard.sh` — regenerates stats, syncs assets into the `.gh-pages/` worktree, commits, pushes. Non-fatal on failure.
- `templates/com.asamr.oraclevps.dashboard.plist.template` — launchd job, runs `publish_dashboard.sh` every 900s.
- `tests/test_generate_stats.py` — pytest unit tests for the generator.
- `tests/fixtures/launch_instance_sample.log` — sample hunt log: two attempt clusters with a sleep gap between them.
- `tests/fixtures/stderr_sample.log` — sample crash log with two `ConnectionResetError` tracebacks.
- `tests/fixtures/launch_instance_unsafe.log` — sample log with one line carrying a fake OCID / IP / home path, for the sanitization test.

**Modified:**
- `.gitignore` — ignore the `.gh-pages/` worktree directory.
- `tests/test_shell_scripts.sh` — add `publish_dashboard.sh` to the `bash -n` syntax-check list.
- `vps-ctl.sh` — add the `publish` subcommand; fold the dashboard launchd agent into `start` / `stop` / `status` / `uninstall`; add an exact-match `agent_loaded` helper.
- `setup_mac.sh` — add an idempotent one-time block: add the `origin` remote, make the repo public, push `main`, do the first publish, enable GitHub Pages.

**Not touched:** `run_loop.sh`, `main.py`, `post_create_vpu_bump.py`, the credential files. The hunt is unaffected by this work.

---

## Task 1: Stats generator

Parses the hunt logs into the sanitized `stats.json` the dashboard consumes. This is the testable core of the feature — a pure function (`build_stats`) plus a thin CLI wrapper (`main`).

**Files:**
- Create: `dashboard/generate_stats.py`
- Create: `tests/test_generate_stats.py`
- Create: `tests/fixtures/launch_instance_sample.log`
- Create: `tests/fixtures/stderr_sample.log`
- Create: `tests/fixtures/launch_instance_unsafe.log`

- [ ] **Step 1: Ensure pytest is available and create the fixtures**

The venv lives at `oracle-freetier-instance-creation/.venv`. Install pytest into it (idempotent — no-op if already present):

```bash
oracle-freetier-instance-creation/.venv/bin/pip install -q pytest
```

Create `tests/fixtures/launch_instance_sample.log` — five attempts in the 10:00 hour, then a >2-hour sleep gap, then three attempts in the 12:00 hour:

```
2026-05-14 10:00:00,100 - INFO - Command: launch_instance--
Output: {'status': 429, 'code': 'TooManyRequests', 'message': 'Too many requests for the user'}
2026-05-14 10:01:01,200 - INFO - Command: launch_instance--
Output: {'status': 500, 'code': 'InternalError', 'message': 'Out of host capacity.'}
2026-05-14 10:02:02,300 - INFO - Command: launch_instance--
Output: {'status': 429, 'code': 'TooManyRequests', 'message': 'Too many requests for the user'}
2026-05-14 10:03:03,400 - INFO - Command: launch_instance--
Output: {'status': 500, 'code': 'InternalError', 'message': 'Out of host capacity.'}
2026-05-14 10:04:04,500 - INFO - Command: launch_instance--
Output: {'status': 502, 'code': 'BadGateway', 'message': 'Bad gateway'}
2026-05-14 12:10:00,000 - INFO - Command: launch_instance--
Output: {'status': 429, 'code': 'TooManyRequests', 'message': 'Too many requests for the user'}
2026-05-14 12:11:01,100 - INFO - Command: launch_instance--
Output: {'status': 500, 'code': 'InternalError', 'message': 'Out of host capacity.'}
2026-05-14 12:12:02,200 - INFO - Command: launch_instance--
Output: {'status': 500, 'code': 'InternalError', 'message': 'Out of host capacity.'}
```

Create `tests/fixtures/stderr_sample.log` — two crash tracebacks (two `ConnectionResetError` occurrences):

```
Traceback (most recent call last):
  File "main.py", line 435, in launch_instance
    launch_instance()
oci.exceptions.RequestException: (ProtocolError('Connection aborted.', ConnectionResetError(54, 'Connection reset by peer')), 'Request Endpoint: POST https://iaas.eu-stockholm-1.oraclecloud.com/20160918/instances')
Traceback (most recent call last):
  File "main.py", line 435, in launch_instance
    launch_instance()
oci.exceptions.RequestException: (ProtocolError('Connection aborted.', ConnectionResetError(54, 'Connection reset by peer')), 'Request Endpoint: POST https://iaas.eu-stockholm-1.oraclecloud.com/20160918/instances')
```

Create `tests/fixtures/launch_instance_unsafe.log` — one attempt whose message carries a fake OCID, an IP, and a home path (must be scrubbed), followed by one clean attempt:

```
2026-05-14 09:00:00,000 - INFO - Command: launch_instance--
Output: {'status': 200, 'code': 'OK', 'message': 'instance ocid1.instance.oc1.fake at 203.0.113.7 cfg /Users/asamr/secret'}
2026-05-14 09:01:00,000 - INFO - Command: launch_instance--
Output: {'status': 429, 'code': 'TooManyRequests', 'message': 'Too many requests for the user'}
```

- [ ] **Step 2: Write the test file**

Create `tests/test_generate_stats.py`:

```python
"""Unit tests for dashboard/generate_stats.py."""
import json
import os
import sys

# Make the dashboard/ directory importable.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "dashboard"))
import generate_stats  # noqa: E402

FIXTURES = os.path.join(os.path.dirname(__file__), "fixtures")
SAMPLE_LAUNCH = os.path.join(FIXTURES, "launch_instance_sample.log")
SAMPLE_STDERR = os.path.join(FIXTURES, "stderr_sample.log")
SAMPLE_UNSAFE = os.path.join(FIXTURES, "launch_instance_unsafe.log")


def _stats(tmp_path, launch=SAMPLE_LAUNCH):
    return generate_stats.build_stats(launch, SAMPLE_STDERR, str(tmp_path))


def test_totals_match_fixture(tmp_path):
    t = _stats(tmp_path)["totals"]
    assert t["attempts"] == 8
    assert t["rate_limited_429"] == 3
    assert t["out_of_capacity_500"] == 4
    assert t["other"] == 1
    assert t["crashes"] == 2


def test_first_and_last_attempt(tmp_path):
    s = _stats(tmp_path)
    assert s["first_attempt"] == "2026-05-14T10:00:00"
    assert s["last_attempt"] == "2026-05-14T12:12:02"


def test_timeline_fills_zero_hours(tmp_path):
    assert _stats(tmp_path)["timeline"] == [
        {"hour": "2026-05-14T10:00", "attempts": 5},
        {"hour": "2026-05-14T11:00", "attempts": 0},
        {"hour": "2026-05-14T12:00", "attempts": 3},
    ]


def test_gaps_detected(tmp_path):
    s = _stats(tmp_path)
    assert s["totals"]["gaps"] == 1
    assert s["totals"]["downtime_seconds"] == 7556
    assert s["gaps"] == [
        {
            "from": "2026-05-14T10:04:04",
            "to": "2026-05-14T12:10:00",
            "duration_seconds": 7556,
        }
    ]


def test_hunting_duration_excludes_downtime(tmp_path):
    # span 10:00:00..12:12:02 = 7922s, minus 7556s downtime = 366s active.
    assert _stats(tmp_path)["hunting_duration_seconds"] == 366


def test_log_tail_is_ordered_and_formatted(tmp_path):
    tail = _stats(tmp_path)["log_tail"]
    assert len(tail) == 8
    assert tail[0] == "2026-05-14 10:00:00  429  Too many requests for the user"
    assert tail[-1] == "2026-05-14 12:12:02  500  Out of host capacity."


def test_status_is_hunting_without_marker(tmp_path):
    s = _stats(tmp_path)
    assert s["status"] == "hunting"
    assert s["instance_created"] is False
    assert s["vpu_bumped"] is False


def test_status_flips_when_marker_present(tmp_path):
    (tmp_path / "INSTANCE_CREATED").write_text("ok\n")
    (tmp_path / "VPU_BUMPED").write_text("ok\n")
    s = _stats(tmp_path)
    assert s["status"] == "instance_created"
    assert s["instance_created"] is True
    assert s["vpu_bumped"] is True


def test_cold_start_missing_log(tmp_path):
    s = generate_stats.build_stats(
        str(tmp_path / "nope.log"), SAMPLE_STDERR, str(tmp_path)
    )
    assert s["totals"]["attempts"] == 0
    assert s["timeline"] == []
    assert s["gaps"] == []
    assert s["log_tail"] == []
    assert s["first_attempt"] is None
    assert s["last_attempt"] is None
    assert s["hunting_duration_seconds"] == 0


def test_sanitization_drops_unsafe_lines(tmp_path):
    s = generate_stats.build_stats(SAMPLE_UNSAFE, SAMPLE_STDERR, str(tmp_path))
    # The line with the OCID / IP / home path is dropped from log_tail entirely.
    assert s["log_tail"] == ["2026-05-14 09:01:00  429  Too many requests for the user"]
    # Nothing unsafe leaks anywhere in the serialized output.
    blob = json.dumps(s)
    assert "ocid1." not in blob
    assert "203.0.113.7" not in blob
    assert "/Users/" not in blob


def test_main_writes_json_file(tmp_path, monkeypatch):
    out = tmp_path / "stats.json"
    monkeypatch.setattr(sys, "argv", [
        "generate_stats.py",
        "--launch-log", SAMPLE_LAUNCH,
        "--stderr-log", SAMPLE_STDERR,
        "--marker-dir", str(tmp_path),
        "--output", str(out),
    ])
    assert generate_stats.main() == 0
    data = json.loads(out.read_text())
    assert data["totals"]["attempts"] == 8
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `oracle-freetier-instance-creation/.venv/bin/python -m pytest tests/test_generate_stats.py -v`
Expected: collection error / all FAIL — `ModuleNotFoundError: No module named 'generate_stats'`.

- [ ] **Step 4: Implement the generator**

Create `dashboard/generate_stats.py`:

```python
"""Parse the Oracle VPS hunt logs into a sanitized stats.json for the dashboard.

Standard library only. build_stats() reads the logs + marker files and returns
the stats dict; main() is the CLI wrapper that writes it as JSON. build_stats()
is a pure function so it can be unit-tested against fixture files.
"""
import argparse
import json
import os
import re
from datetime import datetime, timedelta

# Upstream logs each attempt as a "Command: launch_instance--" line (whose
# timestamp we keep) immediately followed by an "Output: {...}" line.
_COMMAND_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}),\d+ - INFO - Command: launch_instance"
)
_OUTPUT_RE = re.compile(r"^Output: (\{.*\})\s*$")
_STATUS_RE = re.compile(r"'status':\s*(\d+)")
_MESSAGE_RE = re.compile(r"'message':\s*'([^']*)'")

_LOG_TS_FMT = "%Y-%m-%d %H:%M:%S"
_ISO_FMT = "%Y-%m-%dT%H:%M:%S"
_HOUR_FMT = "%Y-%m-%dT%H:00"
_ONE_HOUR = timedelta(hours=1)

# Consecutive attempts farther apart than this mean the Mac was asleep or the
# agent was down. Normal cadence is ~60s, so 5 minutes cleanly separates a
# sleep/downtime hole from ordinary retry jitter.
GAP_THRESHOLD_SECONDS = 300

# Credential-safety backstop: a log_tail line matching any of these is dropped
# entirely rather than published. By construction launch_instance.log lines
# never contain these, but this guarantees it.
_UNSAFE_RES = [
    re.compile(r"ocid1\."),
    re.compile(r"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"),
    re.compile(r"/Users/"),
]


def _is_safe(line):
    return not any(rx.search(line) for rx in _UNSAFE_RES)


def _parse_attempts(launch_log_path):
    """Return [{ts, status, message}] per attempt. Missing/empty log -> []."""
    if not os.path.isfile(launch_log_path):
        return []
    attempts = []
    pending_ts = None
    with open(launch_log_path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            cmd = _COMMAND_RE.match(line)
            if cmd:
                pending_ts = datetime.strptime(cmd.group(1), _LOG_TS_FMT)
                continue
            out = _OUTPUT_RE.match(line)
            if out and pending_ts is not None:
                body = out.group(1)
                status_m = _STATUS_RE.search(body)
                message_m = _MESSAGE_RE.search(body)
                attempts.append({
                    "ts": pending_ts,
                    "status": int(status_m.group(1)) if status_m else 0,
                    "message": message_m.group(1) if message_m else "",
                })
                pending_ts = None
    return attempts


def _count_crashes(stderr_log_path):
    if not os.path.isfile(stderr_log_path):
        return 0
    with open(stderr_log_path, encoding="utf-8", errors="replace") as fh:
        return fh.read().count("ConnectionResetError")


def _build_timeline(attempts):
    """Hourly buckets from first to last attempt, gap-filled with zero hours."""
    if not attempts:
        return []
    counts = {}
    for a in attempts:
        hour = a["ts"].replace(minute=0, second=0, microsecond=0)
        counts[hour] = counts.get(hour, 0) + 1
    cursor, last = min(counts), max(counts)
    timeline = []
    while cursor <= last:
        timeline.append({
            "hour": cursor.strftime(_HOUR_FMT),
            "attempts": counts.get(cursor, 0),
        })
        cursor += _ONE_HOUR
    return timeline


def _build_gaps(attempts):
    """Consecutive attempts more than GAP_THRESHOLD_SECONDS apart -> gap records."""
    gaps = []
    for prev, cur in zip(attempts, attempts[1:]):
        delta = int((cur["ts"] - prev["ts"]).total_seconds())
        if delta > GAP_THRESHOLD_SECONDS:
            gaps.append({
                "from": prev["ts"].strftime(_ISO_FMT),
                "to": cur["ts"].strftime(_ISO_FMT),
                "duration_seconds": delta,
            })
    return gaps


def build_stats(launch_log_path, stderr_log_path, marker_dir):
    """Read the hunt logs + marker files; return the dashboard stats dict."""
    attempts = _parse_attempts(launch_log_path)
    instance_created = os.path.isfile(os.path.join(marker_dir, "INSTANCE_CREATED"))
    vpu_bumped = os.path.isfile(os.path.join(marker_dir, "VPU_BUMPED"))

    gaps = _build_gaps(attempts)
    downtime = sum(g["duration_seconds"] for g in gaps)

    if attempts:
        span = int((attempts[-1]["ts"] - attempts[0]["ts"]).total_seconds())
        hunting_duration = span - downtime
    else:
        hunting_duration = 0

    log_tail = [
        line
        for line in (
            '{}  {}  {}'.format(
                a["ts"].strftime(_LOG_TS_FMT), a["status"], a["message"]
            )
            for a in attempts[-20:]
        )
        if _is_safe(line)
    ]

    return {
        "generated_at": datetime.now().strftime(_ISO_FMT),
        "status": "instance_created" if instance_created else "hunting",
        "instance_created": instance_created,
        "vpu_bumped": vpu_bumped,
        "first_attempt": attempts[0]["ts"].strftime(_ISO_FMT) if attempts else None,
        "last_attempt": attempts[-1]["ts"].strftime(_ISO_FMT) if attempts else None,
        "hunting_duration_seconds": hunting_duration,
        "totals": {
            "attempts": len(attempts),
            "rate_limited_429": sum(1 for a in attempts if a["status"] == 429),
            "out_of_capacity_500": sum(1 for a in attempts if a["status"] == 500),
            "other": sum(1 for a in attempts if a["status"] not in (429, 500)),
            "crashes": _count_crashes(stderr_log_path),
            "gaps": len(gaps),
            "downtime_seconds": downtime,
        },
        "timeline": _build_timeline(attempts),
        "gaps": gaps,
        "log_tail": log_tail,
    }


def main():
    parser = argparse.ArgumentParser(description="Generate the dashboard stats.json")
    parser.add_argument("--launch-log", required=True)
    parser.add_argument("--stderr-log", required=True)
    parser.add_argument("--marker-dir", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    stats = build_stats(args.launch_log, args.stderr_log, args.marker_dir)
    with open(args.output, "w", encoding="utf-8") as fh:
        json.dump(stats, fh, indent=2)
        fh.write("\n")
    print("wrote {}: {} attempts".format(args.output, stats["totals"]["attempts"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `oracle-freetier-instance-creation/.venv/bin/python -m pytest tests/test_generate_stats.py -v`
Expected: 11 passed.

- [ ] **Step 6: Commit**

```bash
git add dashboard/generate_stats.py tests/test_generate_stats.py tests/fixtures/launch_instance_sample.log tests/fixtures/stderr_sample.log tests/fixtures/launch_instance_unsafe.log
git commit -m "feat: dashboard stats generator (counts, timeline, gaps, sanitization)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Dashboard static assets

The three authored files the browser loads. They change rarely — `app.js` reads whatever shape `stats.json` has. Styled per the Axiom "Dark Matter Console" guide.

**Files:**
- Create: `dashboard/index.html`
- Create: `dashboard/style.css`
- Create: `dashboard/app.js`

- [ ] **Step 1: Create the HTML skeleton**

Create `dashboard/index.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta http-equiv="refresh" content="180">
  <title>getOracle · capacity watch</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;700&family=Inter:wght@400&display=swap" rel="stylesheet">
  <link rel="stylesheet" href="style.css">
</head>
<body>
  <header class="band">
    <h1>getOracle · capacity watch</h1>
    <p class="subtitle">eu-stockholm-1 · VM.Standard.A1.Flex</p>
  </header>

  <main>
    <p id="status-line" class="status-line">loading…</p>

    <section class="cards" id="cards"></section>

    <section>
      <h2>ATTEMPTS / HOUR</h2>
      <div class="timeline" id="timeline"></div>
    </section>

    <section>
      <h2>OFFLINE GAPS</h2>
      <ul class="loglist" id="gaps"></ul>
    </section>

    <section>
      <h2>RECENT ACTIVITY</h2>
      <ul class="loglist" id="log-tail"></ul>
    </section>
  </main>

  <footer class="band">
    <p id="footer-caption" class="caption">—</p>
  </footer>

  <script src="app.js"></script>
</body>
</html>
```

- [ ] **Step 2: Create the stylesheet**

Create `dashboard/style.css`:

```css
:root {
  --color-midnight-ink: #000000;
  --color-deep-graphite: #111111;
  --color-charcoal-surface: #191919;
  --color-medium-gray: #3a3a3a;
  --color-stone-accent: #606060;
  --color-light-steel: #b4b4b4;
  --color-almost-white: #eeeeee;
  --color-highlight-orange: #DA5C2C;
  --font-mono: 'IBM Plex Mono', ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
  --font-sans: 'Inter', ui-sans-serif, system-ui, -apple-system, sans-serif;
  --radius: 2px;
  --shadow-subtle: rgba(0, 0, 0, 0.05) 0px 1px 2px 0px;
}

* { box-sizing: border-box; margin: 0; padding: 0; }

body {
  background: var(--color-midnight-ink);
  color: var(--color-light-steel);
  font-family: var(--font-mono);
  font-size: 14px;
  line-height: 1.43;
}

.band {
  background: var(--color-deep-graphite);
  padding: 32px 40px;
}

header h1 {
  font-weight: 700;
  font-size: 24px;
  color: var(--color-almost-white);
}

.subtitle,
.caption {
  font-family: var(--font-sans);
  font-size: 12px;
  color: var(--color-stone-accent);
  margin-top: 8px;
}

main {
  max-width: 960px;
  margin: 0 auto;
  padding: 40px;
  display: flex;
  flex-direction: column;
  gap: 40px;
}

.status-line {
  font-size: 18px;
  color: var(--color-light-steel);
}

.status-line.created {
  font-weight: 700;
  color: var(--color-highlight-orange);
}

.cards {
  display: grid;
  grid-template-columns: repeat(4, 1fr);
  gap: 8px;
}

@media (max-width: 640px) {
  .cards { grid-template-columns: repeat(2, 1fr); }
}

.card {
  background: var(--color-charcoal-surface);
  border: 1px solid var(--color-medium-gray);
  border-radius: var(--radius);
  box-shadow: var(--shadow-subtle);
  padding: 32px;
}

.card .value {
  font-weight: 700;
  font-size: 32px;
  color: var(--color-almost-white);
}

.card .label {
  color: var(--color-light-steel);
  margin-top: 8px;
}

h2 {
  font-size: 12px;
  font-weight: 400;
  color: var(--color-stone-accent);
  margin-bottom: 16px;
}

.timeline {
  display: flex;
  align-items: flex-end;
  gap: 2px;
  height: 120px;
}

.timeline .bar {
  flex: 1;
  min-height: 2px;
  background: var(--color-highlight-orange);
}

.timeline .bar.empty {
  background: var(--color-medium-gray);
}

.loglist {
  list-style: none;
  background: var(--color-charcoal-surface);
  border: 1px solid var(--color-medium-gray);
  border-radius: var(--radius);
  padding: 16px 32px;
}

.loglist li {
  padding: 4px 0;
  white-space: pre;
  overflow-x: auto;
}
```

- [ ] **Step 3: Create the renderer**

Create `dashboard/app.js`:

```javascript
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
    renderStatus(stats);
    renderCards(stats);
    renderTimeline(stats);
    renderGaps(stats);
    renderLogTail(stats);
    document.getElementById("footer-caption").textContent =
      `updated ${stats.generated_at} · auto 15m`;
  } catch (err) {
    document.getElementById("status-line").textContent = "stats unavailable";
  }
}

main();
```

- [ ] **Step 4: Verify the page serves and renders against real data**

Generate a `stats.json` from the Task 1 fixtures into `dashboard/`, then serve the directory:

```bash
python3 dashboard/generate_stats.py \
  --launch-log tests/fixtures/launch_instance_sample.log \
  --stderr-log tests/fixtures/stderr_sample.log \
  --marker-dir /tmp \
  --output dashboard/stats.json
cd dashboard && python3 -m http.server 8765 &
sleep 1
curl -s http://localhost:8765/ | grep -q "getOracle · capacity watch" && echo "HTML OK"
curl -s http://localhost:8765/stats.json | python3 -m json.tool > /dev/null && echo "JSON OK"
kill %1
cd ..
```

Expected: `HTML OK` and `JSON OK`.
Then open `http://localhost:8765/` in a browser manually (re-run the `http.server` line) and confirm: dark layered surfaces, eight stat cards, an orange/grey bar timeline with the middle bar grey (the zero hour), an `OFFLINE GAPS` line, and a recent-activity list. Stop the server when done.

- [ ] **Step 5: Remove the temporary stats.json and commit**

`dashboard/stats.json` is a generated artifact — it must not be committed (it is only ever written into the `.gh-pages/` worktree at publish time).

```bash
rm -f dashboard/stats.json
git add dashboard/index.html dashboard/style.css dashboard/app.js
git commit -m "feat: dashboard static assets (Axiom-styled HTML/CSS/JS)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Publish script and .gitignore

The orchestration script that regenerates the stats, syncs the assets into a `gh-pages` git worktree, and pushes. Built to be self-sufficient (creates the worktree and orphan branch on first run) and non-fatal on every failure.

**Files:**
- Create: `publish_dashboard.sh`
- Modify: `.gitignore`
- Modify: `tests/test_shell_scripts.sh`

- [ ] **Step 1: Create the publish script**

Create `publish_dashboard.sh`:

```sh
#!/bin/zsh
# Regenerate the dashboard's sanitized stats, sync the static assets into the
# gh-pages worktree, and push. Runs every 15 min via the dashboard LaunchAgent
# and on demand via ./vps-ctl.sh publish. Non-fatal on failure — a failed
# publish never disturbs the hunt.

set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM_DIR="$ROOT/oracle-freetier-instance-creation"
DASHBOARD_DIR="$ROOT/dashboard"
WORKTREE="$ROOT/.gh-pages"
BRANCH="gh-pages"
VENV_PYTHON="$UPSTREAM_DIR/.venv/bin/python"

log() { echo "[publish] $*"; }

ensure_worktree() {
  # A valid existing worktree on the gh-pages branch — use it as-is.
  if [ -d "$WORKTREE" ] && \
     [ "$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$BRANCH" ]; then
    return 0
  fi
  # Stale or partial worktree directory — clear it and the registration.
  if [ -e "$WORKTREE" ]; then
    git worktree remove --force "$WORKTREE" 2>/dev/null || true
    rm -rf "$WORKTREE"
  fi
  git worktree prune
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git worktree add "$WORKTREE" "$BRANCH"
  else
    # First run: create the gh-pages branch as an orphan inside the worktree.
    git worktree add --detach "$WORKTREE" HEAD
    git -C "$WORKTREE" checkout --orphan "$BRANCH"
    git -C "$WORKTREE" rm -rf . >/dev/null 2>&1 || true
    git -C "$WORKTREE" commit --allow-empty -m "init gh-pages"
  fi
}

ensure_worktree

if [ ! -x "$VENV_PYTHON" ]; then
  log "venv python missing at $VENV_PYTHON — run ./setup_mac.sh first" >&2
  exit 64
fi

"$VENV_PYTHON" "$DASHBOARD_DIR/generate_stats.py" \
  --launch-log "$UPSTREAM_DIR/launch_instance.log" \
  --stderr-log "$ROOT/logs/stderr.log" \
  --marker-dir "$UPSTREAM_DIR" \
  --output "$WORKTREE/stats.json"

cp "$DASHBOARD_DIR/index.html" "$DASHBOARD_DIR/style.css" "$DASHBOARD_DIR/app.js" "$WORKTREE/"

git -C "$WORKTREE" add -A
if git -C "$WORKTREE" diff --cached --quiet; then
  log "no changes to publish"
  exit 0
fi

git -C "$WORKTREE" commit -m "publish: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null
if git -C "$WORKTREE" push origin "$BRANCH" 2>&1; then
  log "published to gh-pages"
  exit 0
else
  log "push failed — page not updated, hunt unaffected" >&2
  exit 1
fi
```

Make it executable:

```bash
chmod +x publish_dashboard.sh
```

- [ ] **Step 2: Add the worktree directory to .gitignore**

In `.gitignore`, after the `# Python` block (the line `.pytest_cache/`), add a new block:

```
# Dashboard — gh-pages worktree, and the generated stats file (only ever
# belongs in the worktree; the line below guards against an accidental
# commit if it is generated into dashboard/ during local verification).
.gh-pages/
dashboard/stats.json
```

- [ ] **Step 3: Register the script in the shell-syntax test harness**

In `tests/test_shell_scripts.sh`, change the `SCRIPTS` array from:

```sh
SCRIPTS=(
  "$ROOT/setup_mac.sh"
  "$ROOT/run_loop.sh"
  "$ROOT/vps-ctl.sh"
)
```

to:

```sh
SCRIPTS=(
  "$ROOT/setup_mac.sh"
  "$ROOT/run_loop.sh"
  "$ROOT/vps-ctl.sh"
  "$ROOT/publish_dashboard.sh"
)
```

- [ ] **Step 4: Verify syntax and registration**

Run: `bash -n publish_dashboard.sh && ./tests/test_shell_scripts.sh`
Expected: no syntax errors; output includes `OK syntax: .../publish_dashboard.sh` and the harness exits 0.

- [ ] **Step 5: Verify the script runs end-to-end (push expected to fail — no remote yet)**

Run: `./publish_dashboard.sh; echo "exit: $?"`
Expected: it creates the `.gh-pages/` worktree, generates `stats.json`, copies the three assets, commits to the local `gh-pages` branch, then prints `[publish] push failed — page not updated, hunt unaffected` and `exit: 1` (there is no `origin` remote until Task 6).

Confirm the local artifacts and that `main` is unaffected:

```bash
ls .gh-pages/                           # index.html style.css app.js stats.json
git -C .gh-pages log --oneline          # "init gh-pages" + one "publish: ..." commit
git status --short                      # .gh-pages/ must NOT appear
```

- [ ] **Step 6: Commit**

```bash
git add publish_dashboard.sh .gitignore tests/test_shell_scripts.sh
git commit -m "feat: publish_dashboard.sh — sync stats + assets to gh-pages

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Dashboard LaunchAgent plist template

The launchd job definition that runs `publish_dashboard.sh` every 15 minutes. Mirrors the existing hunt-agent template's `__OVPS_ROOT__` substitution pattern.

**Files:**
- Create: `templates/com.asamr.oraclevps.dashboard.plist.template`

- [ ] **Step 1: Create the plist template**

Create `templates/com.asamr.oraclevps.dashboard.plist.template`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.asamr.oraclevps.dashboard</string>

    <key>ProgramArguments</key>
    <array>
        <string>__OVPS_ROOT__/publish_dashboard.sh</string>
    </array>

    <key>WorkingDirectory</key>
    <string>__OVPS_ROOT__</string>

    <key>RunAtLoad</key>
    <true/>

    <key>StartInterval</key>
    <integer>900</integer>

    <key>StandardOutPath</key>
    <string>__OVPS_ROOT__/logs/dashboard.log</string>

    <key>StandardErrorPath</key>
    <string>__OVPS_ROOT__/logs/dashboard.log</string>
</dict>
</plist>
```

- [ ] **Step 2: Verify the substituted plist is valid**

Run:

```bash
sed "s|__OVPS_ROOT__|$(pwd)|g" templates/com.asamr.oraclevps.dashboard.plist.template > /tmp/dash.plist && plutil -lint /tmp/dash.plist && rm /tmp/dash.plist
```

Expected: `/tmp/dash.plist: OK`.

- [ ] **Step 3: Commit**

```bash
git add templates/com.asamr.oraclevps.dashboard.plist.template
git commit -m "feat: dashboard LaunchAgent plist template (15-min interval)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: vps-ctl.sh integration

Add the `publish` subcommand and fold the dashboard launchd agent into the existing `start` / `stop` / `status` / `uninstall` lifecycle, so there is one control surface. Also add an exact-match `agent_loaded` helper — the existing `launchctl list | grep -q "$AGENT_LABEL"` check is a prefix match that would now also match `com.asamr.oraclevps.dashboard`, so it must be made exact.

**Files:**
- Modify: `vps-ctl.sh`

- [ ] **Step 1: Add the dashboard agent variables**

In `vps-ctl.sh`, change the variable block from:

```sh
ROOT="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM_DIR="$ROOT/oracle-freetier-instance-creation"
PLIST_TEMPLATE="$ROOT/templates/com.asamr.oraclevps.plist.template"
PLIST_DEST="$HOME/Library/LaunchAgents/com.asamr.oraclevps.plist"
AGENT_LABEL="com.asamr.oraclevps"
LOG_DIR="$ROOT/logs"
```

to:

```sh
ROOT="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM_DIR="$ROOT/oracle-freetier-instance-creation"
PLIST_TEMPLATE="$ROOT/templates/com.asamr.oraclevps.plist.template"
PLIST_DEST="$HOME/Library/LaunchAgents/com.asamr.oraclevps.plist"
AGENT_LABEL="com.asamr.oraclevps"
DASHBOARD_PLIST_TEMPLATE="$ROOT/templates/com.asamr.oraclevps.dashboard.plist.template"
DASHBOARD_PLIST_DEST="$HOME/Library/LaunchAgents/com.asamr.oraclevps.dashboard.plist"
DASHBOARD_AGENT_LABEL="com.asamr.oraclevps.dashboard"
PAGES_URL="https://asracwl.github.io/getOracle/"
LOG_DIR="$ROOT/logs"
```

- [ ] **Step 2: Add the `agent_loaded` helper**

In `vps-ctl.sh`, immediately after the closing `}` of the `require_setup` function and before the `case "$cmd" in` line, add:

```sh
# Exact-match check: launchctl list <label> exits 0 only if that exact agent
# is loaded (unlike `launchctl list | grep`, which prefix-matches).
agent_loaded() {
  launchctl list "$1" >/dev/null 2>&1
}
```

- [ ] **Step 3: Update the `start` branch to load both agents**

Replace the entire `start)` case branch with:

```sh
  start)
    require_setup
    mkdir -p "$LOG_DIR"
    mkdir -p "$HOME/Library/LaunchAgents"

    sed "s|__OVPS_ROOT__|$ROOT|g" "$PLIST_TEMPLATE" > "$PLIST_DEST"
    plutil -lint "$PLIST_DEST" >/dev/null
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    launchctl load "$PLIST_DEST"

    sed "s|__OVPS_ROOT__|$ROOT|g" "$DASHBOARD_PLIST_TEMPLATE" > "$DASHBOARD_PLIST_DEST"
    plutil -lint "$DASHBOARD_PLIST_DEST" >/dev/null
    launchctl unload "$DASHBOARD_PLIST_DEST" 2>/dev/null || true
    launchctl load "$DASHBOARD_PLIST_DEST"

    if agent_loaded "$AGENT_LABEL" && agent_loaded "$DASHBOARD_AGENT_LABEL"; then
      echo "[vps-ctl] LaunchAgents loaded: $AGENT_LABEL, $DASHBOARD_AGENT_LABEL"
      echo "[vps-ctl] dashboard: $PAGES_URL"
      echo "[vps-ctl] tail logs with: ./vps-ctl.sh logs"
      exit 0
    fi
    echo "[vps-ctl] a LaunchAgent did not appear in launchctl list" >&2
    exit 1
    ;;
```

- [ ] **Step 4: Update the `stop` branch to unload both agents**

Replace the entire `stop)` case branch with:

```sh
  stop)
    if [ ! -f "$PLIST_DEST" ] && [ ! -f "$DASHBOARD_PLIST_DEST" ]; then
      echo "[vps-ctl] not installed (no plists in ~/Library/LaunchAgents)"
      exit 0
    fi
    if [ -f "$PLIST_DEST" ]; then
      launchctl unload "$PLIST_DEST" 2>/dev/null || true
    fi
    if [ -f "$DASHBOARD_PLIST_DEST" ]; then
      launchctl unload "$DASHBOARD_PLIST_DEST" 2>/dev/null || true
    fi
    if agent_loaded "$AGENT_LABEL" || agent_loaded "$DASHBOARD_AGENT_LABEL"; then
      echo "[vps-ctl] FAIL: an agent is still listed after unload" >&2
      exit 1
    fi
    echo "[vps-ctl] LaunchAgents unloaded"
    exit 0
    ;;
```

- [ ] **Step 5: Update the `status` branch to show the dashboard agent**

Replace the entire `status)` case branch with:

```sh
  status)
    echo "--- launchctl ---"
    if agent_loaded "$AGENT_LABEL"; then
      echo "hunt agent:      loaded ($AGENT_LABEL)"
    else
      echo "hunt agent:      (not loaded)"
    fi
    if agent_loaded "$DASHBOARD_AGENT_LABEL"; then
      echo "dashboard agent: loaded ($DASHBOARD_AGENT_LABEL)"
    else
      echo "dashboard agent: (not loaded)"
    fi
    echo
    echo "--- artifacts ---"
    for f in INSTANCE_CREATED VPU_BUMPED ERROR_IN_CONFIG.log UNHANDLED_ERROR.log; do
      if [ -f "$UPSTREAM_DIR/$f" ]; then
        echo "PRESENT: $f"
      else
        echo "absent:  $f"
      fi
    done
    echo
    echo "--- dashboard ---"
    echo "url: $PAGES_URL"
    if [ -f "$LOG_DIR/dashboard.log" ]; then
      last_publish="$(grep "\[publish\]" "$LOG_DIR/dashboard.log" | tail -n 1)"
      if [ -n "$last_publish" ]; then
        echo "last publish: $last_publish"
      else
        echo "last publish: (no publish lines yet)"
      fi
    else
      echo "last publish: (no dashboard.log yet)"
    fi
    echo
    echo "--- last 5 lines of launch_instance.log ---"
    if [ -f "$UPSTREAM_DIR/launch_instance.log" ]; then
      tail -n 5 "$UPSTREAM_DIR/launch_instance.log"
    else
      echo "(no log yet)"
    fi
    exit 0
    ;;
```

- [ ] **Step 6: Add the `publish` branch**

In `vps-ctl.sh`, immediately after the `status)` branch's closing `;;` and before the `logs)` branch, add a new branch:

```sh
  publish)
    require_setup
    mkdir -p "$LOG_DIR"
    echo "[vps-ctl] running dashboard publish in the foreground"
    "$ROOT/publish_dashboard.sh"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "[vps-ctl] publish OK — $PAGES_URL"
    else
      echo "[vps-ctl] publish exited $rc — see output above" >&2
    fi
    exit "$rc"
    ;;
```

- [ ] **Step 7: Update the `uninstall` branch to remove both plists**

Replace the entire `uninstall)` case branch with:

```sh
  uninstall)
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    launchctl unload "$DASHBOARD_PLIST_DEST" 2>/dev/null || true
    removed=0
    if [ -f "$PLIST_DEST" ]; then
      rm "$PLIST_DEST"
      echo "[vps-ctl] removed $PLIST_DEST"
      removed=1
    fi
    if [ -f "$DASHBOARD_PLIST_DEST" ]; then
      rm "$DASHBOARD_PLIST_DEST"
      echo "[vps-ctl] removed $DASHBOARD_PLIST_DEST"
      removed=1
    fi
    [ "$removed" -eq 0 ] && echo "[vps-ctl] no plists to remove"
    exit 0
    ;;
```

- [ ] **Step 8: Update the `help` text**

In the `help|*)` branch's heredoc, replace the command list block:

```
  test       Smoke-test the retry loop in the foreground for ~150s
  start      Install and load the LaunchAgent (auto-restart, runs at login)
  stop       Unload the LaunchAgent (keeps the plist file)
  status     Show agent state, INSTANCE_CREATED/VPU_BUMPED status, last log lines
  logs       Tail stderr.log and launch_instance.log until Ctrl+C
  uninstall  Stop the agent and remove the plist file
  help       Show this message
```

with:

```
  test       Smoke-test the retry loop in the foreground for ~150s
  start      Install and load the hunt + dashboard LaunchAgents
  stop       Unload both LaunchAgents (keeps the plist files)
  status     Show agent state, INSTANCE_CREATED/VPU_BUMPED, dashboard, last log lines
  publish    Regenerate and push the dashboard once, in the foreground
  logs       Tail stderr.log and launch_instance.log until Ctrl+C
  uninstall  Stop both agents and remove the plist files
  help       Show this message
```

- [ ] **Step 9: Verify syntax and the new behavior**

Run:

```bash
bash -n vps-ctl.sh && ./tests/test_shell_scripts.sh
./vps-ctl.sh help
./vps-ctl.sh status
```

Expected: no syntax errors and the harness exits 0; `help` lists the `publish` command; `status` prints both `hunt agent:` and `dashboard agent:` lines (both `(not loaded)` at this point) and a `--- dashboard ---` section.

- [ ] **Step 10: Commit**

```bash
git add vps-ctl.sh
git commit -m "feat: vps-ctl manages dashboard agent + publish subcommand

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: One-time repo setup in setup_mac.sh

Add an idempotent block to `setup_mac.sh` that wires the project to GitHub: add the `origin` remote, make the repo public (GitHub Pages on the free plan requires it), push `main`, do the first dashboard publish (which creates and pushes the `gh-pages` branch), and enable GitHub Pages.

> **Note — this task performs outward-facing, hard-to-reverse actions:** it makes `asraCWL/getOracle` **public** and pushes the local scaffolding to it. This is exactly what the approved spec describes ("Repo visibility flipped to public"). All tracked files are credential-free. The credential directory and `logs/` stay gitignored and never leave the Mac.

**Files:**
- Modify: `setup_mac.sh`

- [ ] **Step 1: Add the GitHub publish-setup block**

In `setup_mac.sh`, between the `# --- create logs dir ---` block (the `mkdir -p "$ROOT/logs"` line) and the `# --- final next-steps checklist ---` block, insert:

```sh
# --- one-time GitHub publish setup (idempotent) ---
GH_REMOTE_URL="https://github.com/asraCWL/getOracle.git"
GH_REPO="asraCWL/getOracle"

if command -v gh >/dev/null 2>&1; then
  if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
    log "git remote 'origin' already set"
  else
    git -C "$ROOT" remote add origin "$GH_REMOTE_URL"
    log "added git remote 'origin' -> $GH_REMOTE_URL"
  fi

  VIS="$(gh repo view "$GH_REPO" --json visibility -q .visibility 2>/dev/null || echo unknown)"
  if [ "$VIS" = "unknown" ]; then
    log "WARNING: cannot read $GH_REPO visibility (is gh authenticated?) — skipping publish setup"
  else
    if [ "$VIS" = "PUBLIC" ]; then
      log "repo $GH_REPO already public"
    else
      gh repo edit "$GH_REPO" --visibility public --accept-visibility-change-consequences
      log "set $GH_REPO visibility to public (required for GitHub Pages on the free plan)"
    fi

    git -C "$ROOT" push -u origin main
    log "pushed main to origin"

    # First publish: creates the gh-pages branch + worktree and pushes the page.
    "$ROOT/publish_dashboard.sh" || log "initial publish reported an issue (continuing)"

    if gh api "repos/$GH_REPO/pages" >/dev/null 2>&1; then
      log "GitHub Pages already enabled for $GH_REPO"
    else
      if echo '{"source":{"branch":"gh-pages","path":"/"}}' \
           | gh api --method POST "repos/$GH_REPO/pages" --input - >/dev/null 2>&1; then
        log "enabled GitHub Pages (gh-pages branch) for $GH_REPO"
      else
        log "WARNING: could not enable GitHub Pages automatically — enable it in"
        log "         repo Settings > Pages: branch 'gh-pages', folder '/ (root)'"
      fi
    fi
  fi
else
  log "WARNING: gh CLI not found — skipping GitHub publish setup (install: brew install gh)"
fi
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n setup_mac.sh && ./tests/test_shell_scripts.sh`
Expected: no syntax errors; the harness exits 0.

- [ ] **Step 3: Run setup_mac.sh and verify the GitHub wiring**

Run: `./setup_mac.sh`
Expected log lines include: `added git remote 'origin' ...` (or `already set`), `set asraCWL/getOracle visibility to public` (or `already public`), `pushed main to origin`, `[publish] published to gh-pages`, and `enabled GitHub Pages ...`.

Then confirm:

```bash
git remote get-url origin                                  # the getOracle URL
gh repo view asraCWL/getOracle --json visibility -q .visibility   # PUBLIC
gh api repos/asraCWL/getOracle/pages -q .html_url          # the Pages URL
```

- [ ] **Step 4: Verify idempotency**

Run: `./setup_mac.sh` again.
Expected: the GitHub block now logs `already set`, `already public`, `Everything up-to-date` (from the push), `[publish] no changes to publish` or a fresh publish, and `GitHub Pages already enabled` — no errors, nothing duplicated.

- [ ] **Step 5: Commit**

```bash
git add setup_mac.sh
git commit -m "feat: setup_mac.sh wires GitHub remote, public repo, Pages

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
git push
```

---

## Final verification

After all six tasks, confirm the whole feature end-to-end:

- [ ] `oracle-freetier-instance-creation/.venv/bin/python -m pytest tests/ -v` — all tests pass (the new `test_generate_stats.py` plus the pre-existing suite).
- [ ] `./tests/test_shell_scripts.sh` — all four scripts pass `bash -n`.
- [ ] `./vps-ctl.sh publish` — exits 0 and prints `publish OK`.
- [ ] Open `https://asracwl.github.io/getOracle/` in a browser — the dashboard renders: header band, `● HUNTING — …h …m active` status line, eight stat cards, the orange/grey hourly timeline, the `OFFLINE GAPS` section, and the `RECENT ACTIVITY` tail. (GitHub Pages can take 1–2 minutes to build after the first publish.)
- [ ] The numbers on the page match `./vps-ctl.sh status` and the tail of `oracle-freetier-instance-creation/launch_instance.log`.
- [ ] `curl -s https://asracwl.github.io/getOracle/stats.json | grep -E 'ocid1\.|/Users/|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'` — returns nothing (no credentials, paths, or IPs leaked).
- [ ] `./vps-ctl.sh start` — loads both agents; `./vps-ctl.sh status` shows both as `loaded`. Wait ~15 minutes (or run `./vps-ctl.sh publish`) and confirm a fresh `publish:` commit lands on the `gh-pages` branch.
- [ ] `git -C .gh-pages log --oneline` shows publish commits; `git log --oneline` on `main` shows none of them — the auto-publish churn stays on `gh-pages`.
