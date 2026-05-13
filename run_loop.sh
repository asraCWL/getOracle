#!/bin/zsh
# LaunchAgent entrypoint. Runs the upstream retry loop, then runs the
# post-creation VPU bump on clean success.

set -u

SCAFFOLD_ROOT="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM_DIR="$SCAFFOLD_ROOT/oracle-freetier-instance-creation"

if [ ! -d "$UPSTREAM_DIR/.venv" ]; then
  echo "[run_loop] venv missing at $UPSTREAM_DIR/.venv — run ./setup_mac.sh first" >&2
  exit 64
fi

cd "$UPSTREAM_DIR"
"$UPSTREAM_DIR/.venv/bin/python" main.py
rc=$?

if [ $rc -eq 0 ] && [ -f INSTANCE_CREATED ]; then
  echo "[run_loop] instance created — running VPU bump"
  "$UPSTREAM_DIR/.venv/bin/python" "$SCAFFOLD_ROOT/post_create_vpu_bump.py" \
    || echo "[run_loop] VPU bump failed; instance is still created and usable" >&2
fi

exit $rc
