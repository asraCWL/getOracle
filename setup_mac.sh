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

# --- scaffold config files from templates (only if missing) ---
copy_if_missing() {
  local src="$1" dst="$2"
  if [ -f "$dst" ]; then
    log "skip (exists): $dst"
  else
    cp "$src" "$dst"
    log "scaffolded: $dst"
  fi
}

copy_if_missing "$ROOT/templates/oci.env.template"     "$UPSTREAM_DIR/oci.env"
copy_if_missing "$ROOT/templates/oci_config.template"  "$UPSTREAM_DIR/oci_config"

# --- create logs dir ---
mkdir -p "$ROOT/logs"

# --- one-time GitHub publish setup (idempotent) ---
GH_REMOTE_URL="https://github.com/asraCWL/getOracle.git"
GH_REPO="asraCWL/getOracle"

if command -v gh >/dev/null 2>&1; then
  if git -C "$ROOT" remote get-url origin >/dev/null 2>&1; then
    log "git remote 'origin' already set"
  else
    git -C "$ROOT" remote add origin "$GH_REMOTE_URL"
    log "added git remote 'origin' -> $GH_REMOTE_URL"
  fi

  # Ensure git uses gh's stored credentials for HTTPS operations
  gh auth setup-git 2>/dev/null || true

  VIS="$(gh repo view "$GH_REPO" --json visibility -q .visibility 2>/dev/null || echo unknown)"
  if [ "$VIS" = "unknown" ]; then
    log "WARNING: cannot read $GH_REPO visibility (is gh authenticated?) — skipping publish setup"
  else
    if [ "$VIS" = "PUBLIC" ]; then
      log "repo $GH_REPO already public"
    else
      gh repo edit "$GH_REPO" --visibility public --accept-visibility-change-consequences
      log "set $GH_REPO visibility to public (required for GitHub Pages on the free plan)"
    fi

    git -C "$ROOT" push -u origin main
    log "pushed main to origin"

    # First publish: creates the gh-pages branch + worktree and pushes the page.
    "$ROOT/publish_dashboard.sh" || log "initial publish reported an issue (continuing)"

    if gh api "repos/$GH_REPO/pages" >/dev/null 2>&1; then
      log "GitHub Pages already enabled for $GH_REPO"
    else
      if echo '{"source":{"branch":"gh-pages","path":"/"}}' \
           | gh api --method POST "repos/$GH_REPO/pages" --input - >/dev/null 2>&1; then
        log "enabled GitHub Pages (gh-pages branch) for $GH_REPO"
      else
        log "WARNING: could not enable GitHub Pages automatically — enable it in"
        log "         repo Settings > Pages: branch 'gh-pages', folder '/ (root)'"
      fi
    fi
  fi
else
  log "WARNING: gh CLI not found — skipping GitHub publish setup (install: brew install gh)"
fi

# --- final next-steps checklist ---
cat <<EOF

[setup_mac] Setup complete. Next steps:

  1. Drop your OCI API private key into:
        $UPSTREAM_DIR/oci_api_private_key.pem

  2. Drop your SSH public key into:
        $UPSTREAM_DIR/ssh_public_key.pub
     (e.g. cp ~/.ssh/id_ed25519.pub $UPSTREAM_DIR/ssh_public_key.pub)

  3. Edit and fill placeholders in:
        $UPSTREAM_DIR/oci_config
        $UPSTREAM_DIR/oci.env
     See docs/superpowers/specs/ for the value list.

  4. Smoke-test the loop:
        ./vps-ctl.sh test

  5. If test passes, install the LaunchAgent:
        ./vps-ctl.sh start

EOF
