#!/usr/bin/env bash
# Create a READY-TO-BUILD git worktree off the dev branch in ONE command. Crucially it runs `--import`,
# WITHOUT which a fresh worktree's .glsl kernels don't compile → load() returns null → the GPU
# MaterialField is SILENTLY DEAD (biomass=0). So always make worktrees with this, then trust SIM_REPORT.
#
#   scripts/new_worktree.sh feature/my-thing            # off the dev branch CLAUDE.md names
#   scripts/new_worktree.sh feature/my-thing <base>     # explicit base
#
# Prints the worktree path on success. Safe to source the path: WT=$(scripts/new_worktree.sh ... | tail -1)
set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_dev_branch.sh"
BRANCH="${1:?usage: new_worktree.sh <branch> [base]}"
BASE="${2:-$(dev_branch)}"
# The MAIN checkout (first worktree) owns the compiled bin we symlink into the new worktree.
PRIMARY="$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
SLUG="$(printf '%s' "$BRANCH" | tr '/' '-')"
WT="$PRIMARY/../la-$SLUG"
BIN="$PRIMARY/addons/local_agents/gdextensions/localagents/bin"
# godot-cpp and llama.cpp are FETCHED dependencies, gitignored and absent from a fresh worktree, so a
# lane touching extension sources cannot configure CMake at all. Shared: a build reads them, never writes.
DEPS="$PRIMARY/addons/local_agents/gdextensions/localagents/thirdparty"

# An EXISTING lane is checked out, not recreated: -b fails on it, and resuming one is the normal case.
if git -C "$PRIMARY" show-ref --verify --quiet "refs/heads/$BRANCH"; then
	git -C "$PRIMARY" worktree add "$WT" "$BRANCH" >&2
else
	git -C "$PRIMARY" worktree add "$WT" -b "$BRANCH" "$BASE" >&2
	MADE_BRANCH=1
fi
# A HALF-MADE WORKTREE IS NOT HANDED BACK. Every step below is load-bearing, so a failure takes the tree
# with it rather than leaving one standing for somebody to find and trust.
abort() {  # abort <what failed> <rc>
	echo "[new_worktree] $1" >&2
	git -C "$PRIMARY" worktree remove --force "$WT" >/dev/null 2>&1 || true
	if [ "${MADE_BRANCH:-0}" = "1" ]; then
		git -C "$PRIMARY" branch -D "$BRANCH" >/dev/null 2>&1 || true
	fi
	exit "$2"
}

# A DANGLING LINK IS WORSE THAN NO LINK: the extension silently fails to load and every class_name reports
# MISSING, which reads as a broken branch rather than an unbuilt one.
[ -d "$BIN" ] || abort "no compiled bin at ${BIN}: build the GDExtension in the primary checkout first." 2
# ITS OWN COPY, NOT A LINK. One shared bin/ cannot serve two trees whose native class_names differ: the
# other tree reports "hides a native class" and every dependent script stops parsing.
rm -rf "$WT/addons/local_agents/gdextensions/localagents/bin"
cp -R "$BIN" "$WT/addons/local_agents/gdextensions/localagents/bin"
if [ -d "$DEPS" ]; then
	ln -sfn "$DEPS" "$WT/addons/local_agents/gdextensions/localagents/thirdparty"
else
	echo "[new_worktree] no fetched thirdparty/ in the primary checkout: this lane cannot configure CMake." >&2
fi
# THE COPIED BIN WAS BUILT FROM THE PRIMARY'S SOURCES, and a branch that changes the extension gets one
# la_extension_current refuses, so neither the import nor the scan below can launch. Build this tree's own.
. "$(dirname "${BASH_SOURCE[0]}")/lib_godot.sh"
if ! la_extension_current "$WT" >/dev/null 2>&1; then
	echo "[new_worktree] extension sources differ from the primary's; building this tree's own bin…" >&2
	"$WT/addons/local_agents/gdextensions/localagents/scripts/build_extension.sh" >&2 \
		|| abort "build_extension.sh FAILED: this tree has no bin it can launch." 1
fi
echo "[new_worktree] importing shaders (compiles .glsl kernels — required or the GPU field is dead)…" >&2
"$(dirname "${BASH_SOURCE[0]}")/godot_import.sh" "$WT" \
	|| abort "--import FAILED: without it load() returns null, the GPU field is silently dead and every SIM_REPORT number is fiction." 1
# Through scripts/editor_scan.sh, never `godot --headless --editor` directly. Two unlocked scans against
# the same .godot/ segfault, and a fresh worktree is exactly when several agents start at once; the
# wrapper takes the per-project lock. It also force-loads
# every script, so a worktree that does not parse is reported here instead of at the first SIM_REPORT.
echo "[new_worktree] editor scan + parse sweep (registers new class_name / .gdextension)…" >&2
scan_rc=0
"$WT/scripts/editor_scan.sh" --path "$WT" >&2 || scan_rc=$?
if [ "$scan_rc" -ne 0 ]; then
	abort "editor scan exited $scan_rc: the tree does not parse." 1
fi
echo "[new_worktree] ready: branch '$BRANCH' off '$BASE'" >&2
echo "$WT"
