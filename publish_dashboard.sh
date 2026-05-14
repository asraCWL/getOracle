#!/bin/zsh
# Regenerate the dashboard's sanitized stats, sync the static assets into the
# gh-pages worktree, and push. Runs every 15 min via the dashboard LaunchAgent
# and on demand via ./vps-ctl.sh publish. Non-fatal on failure — a failed
# publish never disturbs the hunt.

set -u

ROOT="$(cd "$(dirname "$0")" && pwd)"
UPSTREAM_DIR="$ROOT/oracle-freetier-instance-creation"
DASHBOARD_DIR="$ROOT/dashboard"
WORKTREE="$ROOT/.gh-pages"
BRANCH="gh-pages"
VENV_PYTHON="$UPSTREAM_DIR/.venv/bin/python"

log() { echo "[publish] $*"; }

ensure_worktree() {
  # A valid existing worktree on the gh-pages branch — use it as-is.
  if [ -d "$WORKTREE" ] && \
     [ "$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$BRANCH" ]; then
    return 0
  fi
  # Stale or partial worktree directory — clear it and the registration.
  if [ -e "$WORKTREE" ]; then
    git worktree remove --force "$WORKTREE" 2>/dev/null || true
    rm -rf "$WORKTREE"
  fi
  git worktree prune
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git worktree add "$WORKTREE" "$BRANCH"
  else
    # First run: create the gh-pages branch as an orphan inside the worktree.
    git worktree add --detach "$WORKTREE" HEAD
    git -C "$WORKTREE" checkout --orphan "$BRANCH"
    git -C "$WORKTREE" rm -rf . >/dev/null 2>&1 || true
    git -C "$WORKTREE" commit --allow-empty -m "init gh-pages"
  fi
}

if [ ! -x "$VENV_PYTHON" ]; then
  log "venv python missing at $VENV_PYTHON — run ./setup_mac.sh first" >&2
  exit 64
fi

ensure_worktree

"$VENV_PYTHON" "$DASHBOARD_DIR/generate_stats.py" \
  --launch-log "$UPSTREAM_DIR/launch_instance.log" \
  --stderr-log "$ROOT/logs/stderr.log" \
  --marker-dir "$UPSTREAM_DIR" \
  --output "$WORKTREE/stats.json" || {
  log "generate_stats.py failed — skipping publish" >&2
  exit 1
}

cp "$DASHBOARD_DIR/index.html" "$DASHBOARD_DIR/style.css" "$DASHBOARD_DIR/app.js" "$WORKTREE/" || {
  log "asset copy failed — skipping publish" >&2
  exit 1
}

git -C "$WORKTREE" add -A
if git -C "$WORKTREE" diff --cached --quiet; then
  log "no changes to publish"
  exit 0
fi

git -C "$WORKTREE" commit -m "publish: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null
if git -C "$WORKTREE" push origin "$BRANCH"; then
  log "published to gh-pages"
  exit 0
else
  log "push failed — page not updated, hunt unaffected" >&2
  exit 1
fi
