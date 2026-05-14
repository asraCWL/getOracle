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
# Note: [^']* truncates at the first apostrophe. Acceptable because the upstream
# log writes Oracle's Python-repr Output dict and current Oracle messages contain
# no apostrophes.
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
        return sum(line.count("ConnectionResetError") for line in fh)


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
