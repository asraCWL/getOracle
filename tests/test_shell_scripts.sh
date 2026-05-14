#!/bin/zsh
# Minimal shell test harness. Each script gets bash -n syntax check.
# Add new scripts to the SCRIPTS array as they're created.

set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS=(
  "$ROOT/setup_mac.sh"
  "$ROOT/run_loop.sh"
  "$ROOT/vps-ctl.sh"
  "$ROOT/publish_dashboard.sh"
)

fail=0
for s in "${SCRIPTS[@]}"; do
  if [ ! -f "$s" ]; then
    echo "MISSING: $s"
    fail=1
    continue
  fi
  if bash -n "$s"; then
    echo "OK syntax: $s"
  else
    echo "FAIL syntax: $s"
    fail=1
  fi
done

exit $fail
