#!/bin/zsh
# Control surface for the Oracle Free Tier ARM VPS launcher.

set -u

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

cmd="${1:-help}"

require_setup() {
  if [ ! -d "$UPSTREAM_DIR/.venv" ]; then
    echo "venv missing — run ./setup_mac.sh first" >&2
    exit 64
  fi
  if [ ! -f "$UPSTREAM_DIR/oci.env" ] || [ ! -f "$UPSTREAM_DIR/oci_config" ]; then
    echo "oci.env or oci_config missing — run ./setup_mac.sh first" >&2
    exit 64
  fi
  # Match actual placeholder *values* (e.g. =<FILL_IN_FOO>), not the comment
  # header that describes them ("Edit the <FILL_IN_...> placeholders").
  if grep -Eq "=<FILL_IN_[A-Z_]+>" "$UPSTREAM_DIR/oci.env" "$UPSTREAM_DIR/oci_config"; then
    echo "FILL_IN_ placeholders still in config — edit oci.env and oci_config first" >&2
    grep -El "=<FILL_IN_[A-Z_]+>" "$UPSTREAM_DIR/oci.env" "$UPSTREAM_DIR/oci_config" >&2
    exit 65
  fi
  if [ ! -f "$UPSTREAM_DIR/oci_api_private_key.pem" ]; then
    echo "oci_api_private_key.pem missing in $UPSTREAM_DIR" >&2
    exit 65
  fi
  if [ ! -f "$UPSTREAM_DIR/ssh_public_key.pub" ]; then
    echo "ssh_public_key.pub missing in $UPSTREAM_DIR" >&2
    exit 65
  fi
}

# Exact-match check: launchctl list <label> exits 0 only if that exact agent
# is loaded (unlike `launchctl list | grep`, which prefix-matches).
agent_loaded() {
  launchctl list "$1" >/dev/null 2>&1
}

case "$cmd" in
  test)
    require_setup
    mkdir -p "$LOG_DIR"
    echo "[vps-ctl] running foreground smoke test (~150s) — Ctrl+C to abort early"
    cd "$UPSTREAM_DIR"
    perl -e 'alarm 150; exec @ARGV' "$UPSTREAM_DIR/.venv/bin/python" main.py
    rc=$?
    cd "$ROOT"

    LOG_FILE="$UPSTREAM_DIR/launch_instance.log"
    if [ ! -f "$LOG_FILE" ]; then
      echo "[vps-ctl] FAIL: no launch_instance.log produced"
      exit 1
    fi
    # Upstream logs each attempt as "Command: launch_instance--"
    attempts=$(grep -c "Command: launch_instance" "$LOG_FILE" || true)
    echo "[vps-ctl] attempts observed in launch_instance.log: $attempts"
    if [ "$attempts" -ge 2 ]; then
      echo "[vps-ctl] PASS: loop fired at least twice"
      exit 0
    else
      echo "[vps-ctl] FAIL: loop did not fire twice; check $LOG_FILE"
      exit 1
    fi
    ;;

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
    agent_loaded "$AGENT_LABEL"           || echo "[vps-ctl] FAIL: hunt agent not loaded" >&2
    agent_loaded "$DASHBOARD_AGENT_LABEL" || echo "[vps-ctl] FAIL: dashboard agent not loaded" >&2
    exit 1
    ;;

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
      last_publish="$(grep '\[publish\]' "$LOG_DIR/dashboard.log" | tail -n 1)"
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

  logs)
    files=()
    [ -f "$LOG_DIR/stderr.log" ] && files+=("$LOG_DIR/stderr.log")
    [ -f "$UPSTREAM_DIR/launch_instance.log" ] && files+=("$UPSTREAM_DIR/launch_instance.log")
    if [ ${#files[@]} -eq 0 ]; then
      echo "[vps-ctl] no logs yet — start the agent first"
      exit 0
    fi
    echo "[vps-ctl] tailing: ${files[*]} (Ctrl+C to stop)"
    tail -f "${files[@]}"
    ;;

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

  help|*)
    cat <<EOF
vps-ctl.sh — control surface for the Oracle ARM VPS launcher

Usage: ./vps-ctl.sh <command>

  test       Smoke-test the retry loop in the foreground for ~150s
  start      Install and load the hunt + dashboard LaunchAgents
  stop       Unload both LaunchAgents (keeps the plist files)
  status     Show agent state, INSTANCE_CREATED/VPU_BUMPED, dashboard, last log lines
  publish    Regenerate and push the dashboard once, in the foreground
  logs       Tail stderr.log and launch_instance.log until Ctrl+C
  uninstall  Stop both agents and remove the plist files
  help       Show this message

EOF
    [ "$cmd" = "help" ] && exit 0 || exit 64
    ;;
esac
