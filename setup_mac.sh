#!/bin/zsh
# One-time bootstrap for the Oracle Free Tier ARM VPS launcher.
# Idempotent: safe to re-run.

set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM_DIR="$ROOT/oracle-freetier-instance-creation"
UPSTREAM_URL="https://github.com/mohankumarpaluru/oracle-freetier-instance-creation.git"

log()  { echo "[setup_mac] $*"; }
fail() { echo "[setup_mac] ERROR: $*" >&2; exit 1; }

# --- python3 check ---
if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 not found. Install with: brew install python@3.12"
fi
PYVER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
log "python3 found: version $PYVER"

# --- placeholders for next tasks ---
log "TODO: clone upstream, create venv, install deps, scaffold templates"
