#!/usr/bin/env bash
# =====================================================================================================
# A LINKED WORKTREE IS NOT USABLE UNTIL SOMEBODY DOES THREE THINGS. THIS DOES THEM, EVERY TIME.
#
# WHY THIS EXISTS. `git worktree add` gives you the source and nothing else. The three missing pieces do
# not announce themselves — each one degrades quietly, which is the whole problem:
#
#   1. NO `bin/` SYMLINK. The compiled GDExtension is a gitignored build artifact, so a fresh worktree has
#      none and the extension does not load.
#   2. NO IMPORTED KERNELS. A fresh worktree's `.glsl` files are unimported, so `load()` returns null, the
#      GPU MaterialField is SILENTLY DEAD (`biomass` 0, the log full of `get_spirv on a null value`) and
#      every number in SIM_REPORT is fiction that looks fine.
#   3. NO `.godot/`. Every Godot invocation re-imports the whole project first. Measured 2026-08-11 across
#      the seven-agent fan-out: gates that take seconds took THIRTEEN CPU-MINUTES each, and one agent
#      watched another burn 14 minutes on a single check.
#
# CLAUDE.md has told agents to use `scripts/new_worktree.sh` for as long as the section has existed, and it
# is still the right way to MAKE one. But the Workflow tool creates worktrees itself, so no instruction to a
# human or an agent can cover that path — and an instruction is what failed. This runs from
# `agent_harness.sh` on every command, so a worktree cannot be used broken no matter who made it.
#
# IDEMPOTENT AND FAST. When everything is already in place this is a handful of stat calls and prints
# nothing. It only speaks when it changes something or cannot.
#
# EXIT CODES. 0 ready (or nothing to do) · 2 in a worktree that cannot be repaired — never a silent pass,
# because running the suite against a dead GPU field is worse than not running it.
# =====================================================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_REL="addons/local_agents/gdextensions/localagents/bin"
QUIET="${LA_WORKTREE_QUIET:-}"

say() { [[ -n "$QUIET" ]] || echo "worktree_ready: $*" >&2; }

command -v git >/dev/null 2>&1 || exit 0

# A LINKED worktree has a git dir distinct from the common one. The primary checkout is the common dir's
# parent — that is where the build artifacts actually live.
common="$(cd "$REPO_ROOT" && git rev-parse --git-common-dir 2>/dev/null)" || exit 0
gitdir="$(cd "$REPO_ROOT" && git rev-parse --git-dir 2>/dev/null)" || exit 0
[[ "$common" == "$gitdir" ]] && exit 0          # primary checkout: nothing to do, ever
case "$common" in /*) ;; *) common="$REPO_ROOT/$common" ;; esac
PRIMARY="$(cd "$common/.." 2>/dev/null && pwd)" || exit 0
[[ "$PRIMARY" == "$REPO_ROOT" ]] && exit 0

changed=0

# --- 1. the compiled GDExtension --------------------------------------------------------------------
# A DANGLING symlink counts as missing: it is the failure mode of a worktree whose source has moved, and
# `-e` follows the link, so this tests the target rather than the link.
if [[ ! -e "$REPO_ROOT/$BIN_REL" ]]; then
  if [[ -d "$PRIMARY/$BIN_REL" ]]; then
    rm -f "$REPO_ROOT/$BIN_REL"
    mkdir -p "$(dirname "$REPO_ROOT/$BIN_REL")"
    ln -s "$PRIMARY/$BIN_REL" "$REPO_ROOT/$BIN_REL"
    say "linked $BIN_REL -> $PRIMARY/$BIN_REL"
    changed=1
  else
    echo "ERROR: no compiled GDExtension at $PRIMARY/$BIN_REL, and none here." >&2
    echo "       Build it in the primary checkout first. Running the suite without it tests nothing." >&2
    exit 2
  fi
fi

# --- 2 and 3. the import cache -----------------------------------------------------------------------
# One `--import` fixes both: it creates `.godot/` and compiles every `.glsl` into `.godot/imported/`. The
# test is a kernel WITHOUT a compiled resource, which is exactly the silent-death condition — not merely
# "is `.godot` absent", because a half-imported tree is the same failure with a directory in front of it.
needs_import=0
if [[ ! -d "$REPO_ROOT/.godot/imported" ]]; then
  needs_import=1
else
  while IFS= read -r src; do
    base="${src##*/}"
    if ! compgen -G "$REPO_ROOT/.godot/imported/${base}-*.res" >/dev/null 2>&1; then
      needs_import=1
      break
    fi
  done < <(find "$REPO_ROOT/addons/local_agents" -name '*.glsl' -not -path '*/thirdparty/*' 2>/dev/null)
fi

if [[ $needs_import -eq 1 ]]; then
  if ! command -v godot >/dev/null 2>&1; then
    echo "ERROR: this worktree has unimported kernels and godot is not on PATH." >&2
    echo "       load() would return null, the GPU field would be silently dead, and SIM_REPORT would" >&2
    echo "       still print a full set of plausible numbers. Refusing to continue." >&2
    exit 2
  fi
  say "importing (unimported kernels would load as null and the GPU field would be silently dead)"
  if ! timeout 900 godot --headless --path "$REPO_ROOT" --import >/dev/null 2>&1; then
    echo "ERROR: godot --import failed in this worktree. Do not trust any run from it." >&2
    exit 2
  fi
  say "import complete"
  changed=1
fi

[[ $changed -eq 1 ]] && say "worktree ready"
exit 0
