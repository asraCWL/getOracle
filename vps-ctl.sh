#!/bin/zsh
# Control surface for the Oracle Free Tier ARM VPS launcher.

set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM_DIR="$ROOT/oracle-freetier-instance-creation"
PLIST_TEMPLATE="$ROOT/templates/com.asamr.oraclevps.plist.template"
PLIST_DEST="$HOME/Library/LaunchAgents/com.asamr.oraclevps.plist"
AGENT_LABEL="com.asamr.oraclevps"
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
    attempts=$(grep -c "LaunchInstance" "$LOG_FILE" || true)
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
    if launchctl list | grep -q "$AGENT_LABEL"; then
      echo "[vps-ctl] LaunchAgent loaded: $AGENT_LABEL"
      echo "[vps-ctl] tail logs with: ./vps-ctl.sh logs"
      exit 0
    fi
    echo "[vps-ctl] LaunchAgent did not appear in launchctl list" >&2
    exit 1
    ;;

  stop)
    if [ ! -f "$PLIST_DEST" ]; then
      echo "[vps-ctl] not installed (no plist at $PLIST_DEST)"
      exit 0
    fi
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    if launchctl list | grep -q "$AGENT_LABEL"; then
      echo "[vps-ctl] FAIL: still listed after unload" >&2
      exit 1
    fi
    echo "[vps-ctl] LaunchAgent unloaded"
    exit 0
    ;;

  status)
    echo "--- launchctl ---"
    if launchctl list | grep "$AGENT_LABEL"; then :; else echo "(not loaded)"; fi
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
    echo "--- last 5 lines of launch_instance.log ---"
    if [ -f "$UPSTREAM_DIR/launch_instance.log" ]; then
      tail -n 5 "$UPSTREAM_DIR/launch_instance.log"
    else
      echo "(no log yet)"
    fi
    exit 0
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
    if [ -f "$PLIST_DEST" ]; then
      rm "$PLIST_DEST"
      echo "[vps-ctl] removed $PLIST_DEST"
    else
      echo "[vps-ctl] no plist to remove at $PLIST_DEST"
    fi
    exit 0
    ;;

  help|*)
    cat <<EOF
vps-ctl.sh — control surface for the Oracle ARM VPS launcher

Usage: ./vps-ctl.sh <command>

  test       Smoke-test the retry loop in the foreground for ~150s
  start      Install and load the LaunchAgent (auto-restart, runs at login)
  stop       Unload the LaunchAgent (keeps the plist file)
  status     Show agent state, INSTANCE_CREATED/VPU_BUMPED status, last log lines
  logs       Tail stderr.log and launch_instance.log until Ctrl+C
  uninstall  Stop the agent and remove the plist file
  help       Show this message

EOF
    [ "$cmd" = "help" ] && exit 0 || exit 64
    ;;
esac
