"""Unit tests for dashboard/generate_stats.py."""
import json
import os
import sys

import generate_stats

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


def test_orphaned_command_line_at_eof_is_ignored(tmp_path):
    log = tmp_path / "partial.log"
    log.write_text("2026-05-14 13:00:00,000 - INFO - Command: launch_instance--\n")
    s = generate_stats.build_stats(str(log), SAMPLE_STDERR, str(tmp_path))
    assert s["totals"]["attempts"] == 0
