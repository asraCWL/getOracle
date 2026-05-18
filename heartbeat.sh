#!/bin/bash
# Daily health check for the OracleVPS hunt loop on this VM.
# Fires ntfy alerts if the loop looks dead. Sends a positive ping once a week
# (Sundays) so silence isn't the only signal — if a positive ping ever stops
# arriving, you know either ntfy is broken or the VM is.

set -u

NTFY_TOPIC="Oracle_VPS_Heartbeat"
LAUNCH_LOG="/home/ubuntu/OracleVPS/oracle-freetier-instance-creation/launch_instance.log"
SERVICE="oracle-vps-loop.service"
STALE_HOURS=24

ping_alert() {
  curl -fsS \
    -H "Title: $1" \
    -H "Priority: high" \
    -H "Tags: warning" \
    -d "$2" \
    "https://ntfy.sh/$NTFY_TOPIC" >/dev/null || true
}

ping_ok() {
  curl -fsS \
    -H "Title: $1" \
    -H "Priority: low" \
    -H "Tags: green_heart" \
    -d "$2" \
    "https://ntfy.sh/$NTFY_TOPIC" >/dev/null || true
}

# Check 1: service active?
if ! systemctl is-active --quiet "$SERVICE"; then
  ping_alert "OracleVPS loop is DEAD" \
    "systemctl is-active $SERVICE returned: $(systemctl is-active $SERVICE). SSH in and investigate."
  exit 0
fi

# Check 2: launch_instance.log recently written?
if [ -f "$LAUNCH_LOG" ]; then
  log_age_sec=$(( $(date +%s) - $(stat -c %Y "$LAUNCH_LOG") ))
  stale_sec=$(( STALE_HOURS * 3600 ))
  if [ "$log_age_sec" -gt "$stale_sec" ]; then
    ping_alert "OracleVPS loop appears STUCK" \
      "launch_instance.log has not been written in ${log_age_sec}s (>${STALE_HOURS}h). Service says active but isn't polling."
    exit 0
  fi
else
  ping_alert "OracleVPS launch_instance.log MISSING" \
    "Expected file at $LAUNCH_LOG but it's gone."
  exit 0
fi

# Healthy — fire positive ping once a week on Sundays
if [ "$(date +%u)" = "7" ]; then
  log_age_min=$(( log_age_sec / 60 ))
  ping_ok "OracleVPS weekly heartbeat" \
    "Loop is alive. Last poll was ${log_age_min} min ago. Still hunting."
fi
