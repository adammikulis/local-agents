#!/usr/bin/env bash
# Create a READY-TO-BUILD git worktree off the dev branch in ONE command, instead of the 4-step dance
# (add worktree · symlink the compiled bin · import shaders · editor-scan). Crucially it runs `--import`,
# WITHOUT which a fresh worktree's .glsl compute kernels don't compile → load() returns null → the GPU
# MaterialField is SILENTLY DEAD (biomass=0) and the log fills with "get_spirv on a null value". So always
# make worktrees with this, then trust SIM_REPORT.
#
#   scripts/new_worktree.sh feature/my-thing            # off 0.4-dev (default)
#   scripts/new_worktree.sh feature/my-thing 0.4-dev    # explicit base
#
# Prints the worktree path on success. Safe to source the path: WT=$(scripts/new_worktree.sh ... | tail -1)
set -euo pipefail
BRANCH="${1:?usage: new_worktree.sh <branch> [base]}"
BASE="${2:-0.4-dev}"
# The MAIN checkout (first worktree) owns the compiled bin we symlink into the new worktree.
PRIMARY="$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
SLUG="$(printf '%s' "$BRANCH" | tr '/' '-')"
WT="$PRIMARY/../la-$SLUG"
BIN="$PRIMARY/addons/local_agents/gdextensions/localagents/bin"

git -C "$PRIMARY" worktree add "$WT" -b "$BRANCH" "$BASE" >&2
ln -sfn "$BIN" "$WT/addons/local_agents/gdextensions/localagents/bin"
echo "[new_worktree] importing shaders (compiles .glsl kernels — required or the GPU field is dead)…" >&2
godot --headless --path "$WT" --import >/dev/null 2>&1 || echo "[new_worktree] WARN: --import returned nonzero (check manually)" >&2
# Through scripts/editor_scan.sh, never `godot --headless --editor` directly. Two unlocked scans against
# the same .godot/ segfault (six crashes in three minutes, measured 2026-07-28) and a fresh worktree is
# exactly when several agents start at once; the wrapper takes the per-project lock. It also force-loads
# every script, so a worktree that does not parse is reported here instead of at the first SIM_REPORT.
echo "[new_worktree] editor scan + parse sweep (registers new class_name / .gdextension)…" >&2
scan_rc=0
"$PRIMARY/scripts/editor_scan.sh" --path "$WT" >&2 || scan_rc=$?
if [[ "$scan_rc" -ne 0 ]]; then
  echo "[new_worktree] WARN: editor scan exited $scan_rc — the worktree is NOT clean, see above." >&2
fi
echo "[new_worktree] ready: branch '$BRANCH' off '$BASE'" >&2
echo "$WT"
