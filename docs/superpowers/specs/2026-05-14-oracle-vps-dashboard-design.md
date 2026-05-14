# Oracle VPS capacity-watch dashboard — design

**Date:** 2026-05-14
**Owner:** asamr@outlook.dk
**Working directory:** `/Users/asamr/OracleVPS/`
**Builds on:** [2026-05-13-oracle-arm-vps-mac-launcher-design.md](2026-05-13-oracle-arm-vps-mac-launcher-design.md)
**Publish target:** GitHub repo [asraCWL/getOracle](https://github.com/asraCWL/getOracle) — Pages site at `https://asracwl.github.io/getOracle/`

## Goal

Give the running capacity hunt a live web dashboard: a single GitHub Pages page that
shows how the hunt is going at a glance — total attempts, how many were rate-limited
(429) vs. out-of-capacity (500), crash count, time elapsed, an hourly attempts
timeline, and a tail of recent activity. The page refreshes itself every 15 minutes
from a sanitized stats file pushed by a local launchd job. It never publishes
credentials, OCIDs, IPs, or raw config.

## Scope

In scope: a static dashboard page, a Python stats generator, a publish script, a
15-minute launchd job, `vps-ctl.sh` integration, one-time repo setup, and tests for
the generator.

Out of scope: changing the hunt itself (`run_loop.sh`, `main.py`, `post_create_vpu_bump.py`
are untouched); any interactivity beyond a read-only readout; authentication; analytics
beyond what the two log files already contain.

## Architectural approach

**Chosen approach:** static HTML/CSS/JS dashboard + sanitized JSON data, server-side
generated locally and published to a `gh-pages` branch.

The dashboard is three authored files (`index.html`, `style.css`, `app.js`) that
change rarely. A Python generator parses the logs into a sanitized `stats.json`. A
publish script syncs both into a persistent `gh-pages` git worktree, commits, and
pushes. A launchd job runs the publish script every 15 minutes. GitHub Pages serves
the `gh-pages` branch.

**Rejected alternatives:**
- *Server-side rendered single HTML file:* one self-contained file, no JS — but the
  Dovetail-inspired styling would live inside Python string templates (hard to author
  and iterate), and testing would mean parsing generated HTML instead of clean data.
- *React + Vite build:* adds `node_modules` and a build step before Pages can serve
  anything, buys nothing for a read-only data readout.
- *Jekyll / Eleventy static site generator:* build dependency and slower iteration
  for a three-section page. YAGNI.
- *Update on every attempt:* not available — `run_loop.sh` launches `main.py` once
  and `main.py` runs the retry loop internally for hours, so there is no per-attempt
  hook to fire on.

## Repository & branch layout

The local repo at `/Users/asamr/OracleVPS/` currently has no remote and one branch
(`main`). This design adds:

- **`origin` remote** → `https://github.com/asraCWL/getOracle.git`
- **`main` branch** pushed to `origin` — the full existing scaffolding (scripts,
  `.template` placeholder files, sanitized test fixture, docs). All tracked files are
  already credential-free; the credential-bearing `oracle-freetier-instance-creation/`
  directory and `logs/` are gitignored and never leave the Mac.
- **`gh-pages` orphan branch** — contains only the published site: `index.html`,
  `style.css`, `app.js`, `stats.json`. GitHub Pages serves from this branch's root.
  All the 15-minute auto-commit churn lives here, keeping `main` history clean.
- **Repo visibility flipped to public** — required for GitHub Pages on the free plan.
  Safe because every published artifact is sanitized (see "Sanitization boundary").

```
/Users/asamr/OracleVPS/                     (branch: main, pushed to origin)
├── dashboard/
│   ├── index.html                          # page structure
│   ├── style.css                           # Dovetail-inspired styling
│   ├── app.js                              # fetch stats.json, render
│   └── generate_stats.py                   # logs -> sanitized stats.json
├── publish_dashboard.sh                    # regenerate + sync + commit + push
├── templates/
│   └── com.asamr.oraclevps.dashboard.plist.template
├── tests/
│   ├── test_generate_stats.py              # unit tests for the generator
│   └── fixtures/
│       ├── launch_instance_sample.log      # sample upstream log
│       └── stderr_sample.log               # sample crash log
├── .gh-pages/                              # persistent worktree (gitignored)
└── logs/dashboard.log                      # launchd job stdout/stderr (gitignored)
```

## Components

### `dashboard/generate_stats.py`

A pure function: read the log files and marker files, return a stats dict, write it
as `stats.json`. Takes the upstream directory and an output path as arguments so it
is testable against fixtures.

Inputs:
- `oracle-freetier-instance-creation/launch_instance.log` — attempt lines
- `logs/stderr.log` — crash tracebacks (counted only)
- `oracle-freetier-instance-creation/INSTANCE_CREATED` — existence checked (boolean only)
- `oracle-freetier-instance-creation/VPU_BUMPED` — existence checked (boolean only)

Parsing:
- Each attempt is an upstream log pair: a `Command: launch_instance--` line followed
  by an `Output: {...}` line carrying a `status` code. Count attempts; bucket by
  status (`429` → rate-limited, `500` → out-of-capacity, anything else → other).
- `first_attempt` / `last_attempt` come from the first and last attempt timestamps.
  Timestamps are emitted as naive local ISO (`YYYY-MM-DDTHH:MM:SS`) because the
  upstream logger writes local time with no zone.
- `crashes` = count of `ConnectionResetError` occurrences in `stderr.log`.
- `timeline` = attempts grouped into hourly buckets, each `{hour, attempts}`. The
  range is filled — every hour between the first and last attempt appears, even ones
  with zero attempts — so sleep gaps are visible as empty bars.
- `gaps` = pairs of consecutive attempts more than `GAP_THRESHOLD_SECONDS` (300s)
  apart. The Mac is not always on; when it sleeps the hunt pauses and resumes on
  wake, leaving a multi-minute-to-multi-hour hole. Each gap is recorded as
  `{from, to, duration_seconds}`. `totals.gaps` counts them and
  `totals.downtime_seconds` sums their durations.
- `hunting_duration_seconds` = active hunting time =
  `(last_attempt − first_attempt) − totals.downtime_seconds`. The offline gaps are
  subtracted, so this reflects time the Mac was actually hunting — not wall-clock
  time since the first attempt.
- `log_tail` = the last 20 parsed attempt lines, each reduced to
  `"<timestamp>  <status>  <short message>"`.

Output `stats.json` shape:

```json
{
  "generated_at": "2026-05-14T11:33:58",
  "status": "hunting",
  "instance_created": false,
  "vpu_bumped": false,
  "first_attempt": "2026-05-13T22:41:00",
  "last_attempt": "2026-05-14T11:32:59",
  "hunting_duration_seconds": 35119,
  "totals": {
    "attempts": 742,
    "rate_limited_429": 371,
    "out_of_capacity_500": 365,
    "other": 6,
    "crashes": 8,
    "gaps": 3,
    "downtime_seconds": 11200
  },
  "timeline": [
    { "hour": "2026-05-14T10:00", "attempts": 58 },
    { "hour": "2026-05-14T11:00", "attempts": 33 }
  ],
  "gaps": [
    { "from": "2026-05-14T01:52:00", "to": "2026-05-14T02:52:00", "duration_seconds": 3600 }
  ],
  "log_tail": [
    "2026-05-14 11:31:59  500  Out of host capacity",
    "2026-05-14 11:32:59  429  Too many requests"
  ]
}
```

`status` is `"hunting"` normally and `"instance_created"` once the `INSTANCE_CREATED`
marker exists. If `launch_instance.log` is missing or empty, the generator still emits
a valid `stats.json` with zero totals, an empty timeline, an empty `gaps` list, an
empty `log_tail`, and null `first_attempt` / `last_attempt` — the page must render
cleanly on a cold start.

### Sanitization boundary

This is the credential-safety contract. The published `stats.json` may contain only:
counts, ISO timestamps, integer status codes, booleans, and parsed attempt lines
(timestamp + status code + short message).

Rules:
- `log_tail` is built **only** from `launch_instance.log`. Those lines are inherently
  free of OCIDs, IPs, and keys. `stderr.log` contributes **only** the integer crash
  count — its raw traceback text (which contains `/Users/<name>/` paths) is never
  emitted.
- `INSTANCE_CREATED` and `VPU_BUMPED` are read as booleans only. Their contents — the
  real instance OCID, boot volume OCID, and public IP — are never parsed into
  `stats.json`.
- Defensive scrub: every string about to be written to `stats.json` is checked
  against `ocid1\.`, an IPv4 regex, and `/Users/`. Any string that matches is dropped
  entirely (excluded from output) rather than published. This is a backstop — by
  construction nothing should match — and the generator's tests assert it holds.

### `dashboard/index.html`, `style.css`, `app.js`

A single centered-column page, styled after the Dovetail "Midnight Command Center"
design guide: layered dark surfaces — `#0a0a0a` page background (Midnight Charcoal),
`#141414` for the header/footer bands and cards (Off-Black) — with a single vivid
`#6798ff` Data Blue accent reserved strictly for data points and the active state.
Inter for headings, the status line, and the big stat numbers (with the guide's
negative letter-spacing); JetBrains Mono for the small functional text — section
labels, card labels, and the log/gap lines. Both loaded from Google Fonts with
system fallback stacks. 8px border radius, `#313131` Medium Gray borders, no shadows,
32px section gaps, 16px card padding.

Page sections, top to bottom:
1. **Header** — a `#141414` band: title `getOracle · capacity watch` (Inter 600,
   24px, Polar White `#ffffff`), subtitle `eu-stockholm-1 · VM.Standard.A1.Flex` in
   JetBrains Mono, Dim Gray `#7c7c7c`.
2. **Status line** — `● HUNTING — 9h 45m active` in Polar White `#ffffff` (Inter
   500). When `status === "instance_created"`, it reads `✦ INSTANCE CREATED` in Data
   Blue `#6798ff` — the active state, the guide's sanctioned accent use.
3. **Stat cards** — a grid of eight `#141414` cards (8px radius, 16px padding, 1px
   `#313131` border, no shadow): a large number in Polar White (Inter 600, 32px) over
   a JetBrains Mono label in Dim Gray. Cards: attempts, 429 rate-limited, 500
   out-of-capacity, crashes, offline gaps, downtime, last attempt time, attempts/hour.
4. **Timeline** — `ATTEMPTS / HOUR` heading over a CSS bar chart, one bar per hourly
   bucket from `timeline`. Active-hour bars are Data Blue `#6798ff` — the data-point
   accent the guide reserves it for — on the `#0a0a0a` base. Zero-attempt hours render
   as a dim Medium Gray `#313131` ghost bar, so the stretches where the Mac was asleep
   read clearly as offline rather than just low activity.
5. **Log tail** — `RECENT ACTIVITY` heading over a JetBrains Mono list of the ~20
   `log_tail` lines in Silver Dust `#a7a7a7`.
6. **Offline gaps** — `OFFLINE GAPS` heading over a JetBrains Mono list, one line per
   entry in `gaps`: `<from> → <to>  (<human duration>)` in Silver Dust. The Mac is
   not always on, so this section makes each sleep/downtime hole explicit. Shows
   `none` when the list is empty.
7. **Footer** — a `#141414` band: caption `updated <generated_at> · auto 15m` in
   JetBrains Mono, Dim Gray.

`app.js` (~60 lines, no dependencies): on load, `fetch('stats.json')`, populate the
numbers, build the timeline bars, fill the log tail, stamp the footer, and apply the
Data Blue active state if `status === "instance_created"`. `index.html` carries a
`<meta http-equiv="refresh">` tag so an open tab reloads every few minutes and stays
current. On a `fetch` failure the page shows a plain "stats unavailable" line rather
than breaking.

### `publish_dashboard.sh`

Orchestrates one publish cycle. Steps:
1. Ensure the `.gh-pages/` worktree exists and is checked out to the `gh-pages`
   branch. On first run, create the orphan branch and the worktree.
2. Run `dashboard/generate_stats.py`, writing `stats.json` into the worktree.
3. Copy `dashboard/index.html`, `style.css`, `app.js` into the worktree.
4. `git -C .gh-pages add -A`; if there is nothing to commit, exit 0 quietly.
   Otherwise commit (message includes the UTC timestamp) and `git push`.
5. Non-fatal on every failure: a failed publish logs to stderr and exits non-zero,
   but because it runs as its own launchd job it can never disturb the hunt.

Run by the launchd job every 15 minutes, and on demand via `./vps-ctl.sh publish`.

### LaunchAgent — `com.asamr.oraclevps.dashboard`

A second LaunchAgent, separate from the hunt agent so the two never interfere.
Built from `templates/com.asamr.oraclevps.dashboard.plist.template` using the same
`__OVPS_ROOT__` substitution pattern as the existing plist.

Key properties:
- `Label`: `com.asamr.oraclevps.dashboard`
- `ProgramArguments`: `["__OVPS_ROOT__/publish_dashboard.sh"]`
- `WorkingDirectory`: `__OVPS_ROOT__`
- `RunAtLoad`: `true` (publishes once immediately on load)
- `StartInterval`: `900` (every 15 minutes)
- `StandardOutPath` / `StandardErrorPath`: `__OVPS_ROOT__/logs/dashboard.log`

No `KeepAlive` — this is an interval job, not a long-running process.

### `vps-ctl.sh` integration

The dashboard agent folds into the existing control surface so there is one set of
commands:

| Command | Added behavior |
| --- | --- |
| `start` | After loading the hunt agent, also install + load the dashboard agent. |
| `stop` | Also unload the dashboard agent. |
| `status` | Add a "dashboard agent" line, the last publish time (from `logs/dashboard.log`), and the live Pages URL. |
| `uninstall` | Also unload + remove the dashboard plist. |
| `publish` | **New.** Run `publish_dashboard.sh` once, in the foreground, on demand. |

`require_setup` is unchanged — the dashboard does not need OCI credentials, but it
runs alongside the hunt which does, so reusing the existing gate is fine.

### One-time repo setup

Folded into `setup_mac.sh` as an idempotent block (each step checks whether it is
already done and skips if so):
1. `git remote add origin https://github.com/asraCWL/getOracle.git` (skip if present).
2. `gh repo edit asraCWL/getOracle --visibility public --accept-visibility-change-consequences`
   (skip if already public).
3. `git push -u origin main`.
4. Create the `gh-pages` orphan branch with an initial empty commit and push it
   (skip if the branch already exists on the remote).
5. Enable Pages via `gh api` pointing at the `gh-pages` branch root (skip if Pages is
   already configured).
6. `git worktree add .gh-pages gh-pages` (skip if the worktree already exists).

Requires the `gh` CLI authenticated as `asraCWL` — already the case in this
environment.

### `.gitignore` additions

```
.gh-pages/
```

`logs/` and `*.log` are already ignored, which covers `logs/dashboard.log`.
`stats.json` is generated directly into the `.gh-pages/` worktree, never into the
`main` working tree, so it needs no separate ignore rule.

## Data flow

```
launch_instance.log ┐
logs/stderr.log     ├─> generate_stats.py ─> stats.json (sanitized, in .gh-pages/)
INSTANCE_CREATED    │
VPU_BUMPED          ┘
dashboard/index.html ┐
dashboard/style.css  ├─> copied into .gh-pages/ worktree
dashboard/app.js     ┘
                         │
                         ▼
              git commit + push (gh-pages branch)
                         │
                         ▼
              GitHub Pages serves https://asracwl.github.io/getOracle/
                         │
                         ▼
              browser fetches stats.json, app.js renders the page
```

## Error handling

| Failure mode | Behavior |
| --- | --- |
| `launch_instance.log` missing or empty (cold start) | Generator emits a valid zero-state `stats.json`; page renders "0 attempts" cleanly. |
| A string destined for `stats.json` matches the OCID/IP/path scrub patterns | That string is dropped from output entirely; generator tests assert this path works. |
| `generate_stats.py` exits non-zero during a publish | `publish_dashboard.sh` logs the failure and exits 1 without copying assets or committing — no half-built page is published. The hunt is unaffected. Next 15-minute run retries. |
| `publish_dashboard.sh` cannot reach GitHub (network down) | Logs the failure to `logs/dashboard.log`, exits non-zero. The hunt is unaffected. Next 15-minute run retries. |
| `gh-pages` worktree missing or corrupted | Publish script detects its absence and recreates it before generating. |
| Nothing changed since the last publish | `git` finds no diff; the script exits 0 without committing. |
| Browser `fetch('stats.json')` fails | `app.js` shows a "stats unavailable" line instead of a broken page. |
| `gh` CLI not authenticated during one-time setup | `setup_mac.sh` fails fast with a clear message; no partial remote state is left behind. |

## Testing strategy

1. **`test_generate_stats.py`** (pytest) against `tests/fixtures/`:
   - Counts: attempts, 429, 500, other, crashes match the fixture content.
   - Timeline: hourly bucketing is correct, including an hour with zero attempts
     between two active hours.
   - Gaps: a fixture with a greater-than-5-minute jump between consecutive attempts
     produces one `gaps` entry with the right `from` / `to` / `duration_seconds`, and
     `totals.gaps` / `totals.downtime_seconds` match.
   - `log_tail`: contains the last 20 parsed lines in order.
   - Cold start: missing/empty `launch_instance.log` yields a valid zero-state JSON.
   - Sanitization: a fixture line containing a fake `ocid1.` value, an IPv4 address,
     and a `/Users/` path is dropped from `log_tail`; no such string appears anywhere
     in the output.
   - Status flips to `"instance_created"` when the marker file is present.
2. **Shell syntax:** `publish_dashboard.sh` is added to the `SCRIPTS` array in
   `tests/test_shell_scripts.sh` for the `bash -n` check.
3. **Manual verification:** after `./vps-ctl.sh publish`, confirm `gh-pages` has the
   four files, the Pages URL renders, the numbers match `./vps-ctl.sh status`, and
   `stats.json` contains no `ocid1.` / IP / `/Users/` strings (grep check).

## Success criteria

- `./vps-ctl.sh publish` regenerates `stats.json`, syncs the assets, commits to
  `gh-pages`, and pushes — exiting 0.
- `https://asracwl.github.io/getOracle/` renders the dashboard with counts, an hourly
  timeline, and a recent-activity tail that match `./vps-ctl.sh status`.
- Sleep/downtime gaps are visible: the timeline dims zero-attempt hours and the
  `OFFLINE GAPS` section lists each hole with its duration.
- `./vps-ctl.sh start` loads both the hunt agent and the 15-minute dashboard agent;
  `./vps-ctl.sh status` shows both plus the live URL.
- `grep` for `ocid1.`, IPv4 patterns, or `/Users/` in the published `stats.json`
  returns nothing.
- `test_generate_stats.py` passes, including the sanitization and cold-start cases.
- `main` branch history stays free of auto-generated `stats.json` commits — all
  publish churn is on `gh-pages`.
