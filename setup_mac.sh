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

# --- clone or update upstream ---
if [ -d "$UPSTREAM_DIR/.git" ]; then
  log "upstream already cloned; running git pull"
  git -C "$UPSTREAM_DIR" pull --ff-only
else
  log "cloning upstream from $UPSTREAM_URL"
  git clone "$UPSTREAM_URL" "$UPSTREAM_DIR"
fi
log "upstream ready at $UPSTREAM_DIR"

# --- create venv and install deps ---
VENV="$UPSTREAM_DIR/.venv"
if [ ! -d "$VENV" ]; then
  log "creating venv at $VENV"
  python3 -m venv "$VENV"
else
  log "venv already exists at $VENV"
fi

log "upgrading pip"
"$VENV/bin/pip" install --quiet --upgrade pip

REQS="$UPSTREAM_DIR/requirements.txt"
if [ -f "$REQS" ]; then
  log "installing upstream requirements"
  "$VENV/bin/pip" install --quiet -r "$REQS"
else
  fail "upstream requirements.txt not found at $REQS"
fi
log "venv ready with upstream deps"

# --- placeholders for next tasks ---
log "TODO: scaffold templates"
