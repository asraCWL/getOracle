#!/bin/bash
# LaunchAgent entrypoint. Runs the upstream retry loop, then runs the
# post-creation VPU bump on clean success.

set -u

SCAFFOLD_ROOT="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM_DIR="$SCAFFOLD_ROOT/oracle-freetier-instance-creation"
NTFY_TOPIC="Oracle_VPS_Created"

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

  # Notify phone via ntfy.sh. Only fires once: NTFY_SENT marker prevents
  # duplicate pings if the agent ever re-runs after success.
  if [ ! -f NTFY_SENT ]; then
    body="$(cat INSTANCE_CREATED 2>/dev/null)"
    [ -f VPU_BUMPED ] && body="$body

$(cat VPU_BUMPED)"
    if curl -fsS \
         -H "Title: Oracle ARM VPS created" \
         -H "Priority: high" \
         -H "Tags: rocket" \
         -d "$body" \
         "https://ntfy.sh/$NTFY_TOPIC" >/dev/null; then
      touch NTFY_SENT
      echo "[run_loop] ntfy notification sent"
    else
      echo "[run_loop] ntfy notification failed (instance still created)" >&2
    fi
  fi
fi

exit $rc
