#!/usr/bin/env bash
# THE ONE WAY TO LAND A LANE. Never `git merge` into the dev branch by hand.
#   1. Refuses a worktree on a detached HEAD or holding uncommitted changes.
#   2. Merges and gates on a staging branch in its own worktree; the dev branch moves only when green.
#   3. Writes the ceilings, so no lane carries the number.
#   4. Prunes the lane.
#
# USAGE
#   scripts/integrate.sh <branch> ["merge subject"]
#   scripts/integrate.sh --check <branch>     # steps 1 and 2 only; touches nothing
#
# EXIT 0 landed · 1 refused or the gates failed (nothing moved) · 2 the command could not run.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ROOT is where the CALLER is standing, not where this script happens to live: integration is a property
# of the checkout you run it in, and a lane's copy of this file must still refuse to run from the lane.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
[ -n "$ROOT" ] || { echo "integrate: not inside a git checkout." >&2; exit 2; }
. "$SCRIPT_DIR/lib_require.sh" 2>/dev/null || true
require_tool git
require_tool rg

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then CHECK_ONLY=1; shift; fi
BRANCH="${1:-}"
[ -n "$BRANCH" ] || { echo "usage: integrate.sh [--check] <branch> [\"merge subject\"]" >&2; exit 2; }
SUBJECT="${2:-merge($BRANCH)}"

DEV="$(rg -N -o -e '\*\*The current development branch is `[^`]+`' "$ROOT/CLAUDE.md" 2>/dev/null \
	| head -1 | sed -E 's/.*`([^`]+)`.*/\1/')"
[ -n "$DEV" ] || { echo "integrate: CLAUDE.md does not name the dev branch." >&2; exit 2; }

# Integration runs from the PRIMARY checkout: it is the only tree whose branch is the dev branch.
PRIMARY="$(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
[ -n "$PRIMARY" ] || { echo "integrate: no primary checkout in this worktree list." >&2; exit 2; }
# It KNOWS where the primary is, so it goes there rather than refusing. The lane is still verified by its
# own path below; only the merge moves to the tree whose branch is the dev branch.
if [ "$PRIMARY" != "$ROOT" ]; then
	echo "integrate: run from $ROOT; merging in the primary checkout $PRIMARY." >&2
	ROOT="$PRIMARY"
	cd "$ROOT" || { echo "integrate: cannot enter $ROOT." >&2; exit 2; }
fi
git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BRANCH" || { echo "integrate: no branch '$BRANCH'." >&2; exit 2; }

# --- 1. REFUSE A TREE SOMEBODY IS STILL WRITING IN -----------------------------------------------------
# Scoped to the tree holding THIS branch. Other lanes are mid-edit by design -- refusing on their dirtiness
# would mean nothing can land while anything else is running, and a tool that blocks the normal case is a
# tool people route around.
refused=0
while IFS= read -r line; do
	wt="${line#worktree }"
	[ "$wt" = "$PRIMARY" ] && continue
	head_ref="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null || echo "")"
	if [ -z "$head_ref" ]; then
		# A detached HEAD anywhere is worth naming: it is how a lane's commits get orphaned. It only
		# REFUSES when it is the tree this run would take work from.
		echo "integrate: note - $wt is on a DETACHED HEAD; work there belongs to no branch." >&2
		continue
	fi
	[ "$head_ref" = "$BRANCH" ] || continue
	if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
		echo "integrate: $wt holds $BRANCH and has uncommitted changes. Its owner is still writing." >&2
		echo "           Stop the agent before taking its work." >&2
		refused=1
	fi
done < <(git -C "$ROOT" worktree list --porcelain | rg -N '^worktree ')
[ "$refused" -eq 0 ] || exit 1

# --- 2. THE ARITHMETIC, BOTH DIRECTIONS ----------------------------------------------------------------
echo "integrate: $BRANCH -> $DEV" >&2
echo "  ahead of $DEV:" >&2
git -C "$ROOT" log --oneline "$DEV..$BRANCH" | sed 's/^/    /' >&2
behind="$(git -C "$ROOT" log --oneline "$BRANCH..$DEV" | wc -l | tr -d ' ')"
echo "  behind $DEV by $behind commit(s)" >&2
if [ -z "$(git -C "$ROOT" log --oneline "$DEV..$BRANCH")" ]; then
	echo "integrate: $BRANCH holds nothing $DEV does not. Nothing to land -- prune it instead." >&2
	exit 1
fi
[ "$CHECK_ONLY" -eq 0 ] || { echo "integrate: --check only, nothing moved." >&2; exit 0; }

# --- 3. VERIFY THE LANE'S OWN TREE, BECAUSE THAT IS WHAT LANDS ------------------------------------------
# THERE IS NO STAGING TREE. It provisioned a whole environment for the PRE-MERGE source, merged into it,
# and then had to rebuild the extension, re-import the kernels and re-scan to catch up -- three full lints
# and a cold dependency build to check a RECONSTRUCTION of the merge rather than the commit it publishes.
# The lane's own worktree already contains $DEV, is already built, imported and scanned, and its tip is
# exactly what fast-forwards. Linting it is both far cheaper and a stronger claim.
if [ "$behind" -ne 0 ]; then
	echo "integrate: $BRANCH is behind $DEV by $behind commit(s), so its tree is not what would land." >&2
	echo "           Merge $DEV into it IN ITS OWN WORKTREE -- the build is warm there and a conflict is" >&2
	echo "           a physics decision you want the tree in front of you for -- then re-run." >&2
	exit 1
fi

LANE_WT=""
while IFS= read -r line; do
	wt="${line#worktree }"
	[ "$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)" = "$BRANCH" ] || continue
	LANE_WT="$wt"
	break
done < <(git -C "$ROOT" worktree list --porcelain | rg -N '^worktree ')
if [ -z "$LANE_WT" ]; then
	echo "integrate: $BRANCH is checked out in no worktree. Make one with scripts/new_worktree.sh." >&2
	exit 2
fi
echo "integrate: verifying $LANE_WT" >&2

# The integrator owns the ceilings. --no-verify because the hook's whole job is the lint that runs three
# lines below, on this same tree: without it every landing pays for two.
LANE_CEILINGS="$LANE_WT/scripts/write_ceilings.sh"
[ -x "$LANE_CEILINGS" ] || { echo "integrate: $LANE_WT has no write_ceilings.sh." >&2; exit 2; }
LA_CEILING_STRICT=1 "$LANE_CEILINGS" "$LANE_WT" >&2 || true
if [ -n "$(git -C "$LANE_WT" status --porcelain)" ]; then
	git -C "$LANE_WT" add -A
	if ! git -C "$LANE_WT" commit -q --no-verify -m "chore(ceilings): the post-merge counts"; then
		echo "integrate: could not commit the ceilings. $DEV is untouched." >&2
		exit 1
	fi
fi

# A LANE LINTS AGAINST ITS OWN BIN. After a merge that changed native sources that bin is stale and
# la_godot refuses every launch, so the lint examines nothing: rebuild it here, before a gate runs.
. "$SCRIPT_DIR/lib_godot.sh"
LANE_BIN_REL="addons/local_agents/gdextensions/localagents/bin"
if [ "$(cat "$LANE_WT/$LANE_BIN_REL/SOURCE_HASH" 2>/dev/null || echo "")" != "$(la_extension_hash "$LANE_WT")" ]; then
	echo "integrate: the lane's bin does not match its sources; building before the gates." >&2
	"$LANE_WT/addons/local_agents/gdextensions/localagents/scripts/build_extension.sh" --platform macos >/dev/null 2>&1 \
		|| { echo "integrate: build_extension.sh FAILED in the lane. $DEV is untouched." >&2; exit 1; }
	"$LANE_WT/scripts/godot_import.sh" "$LANE_WT" || true
fi

echo "integrate: gates, on the tree that will land" >&2
# THE LANE'S OWN harness: $SCRIPT_DIR/agent_harness.sh computes its repo root from its own location, so it
# would lint the PRIMARY no matter what the cwd is. cd is not enough; the path has to be the lane's.
LANE_LINT="$LANE_WT/scripts/agent_harness.sh"
[ -x "$LANE_LINT" ] || { echo "integrate: $LANE_WT has no harness." >&2; exit 2; }
# A VIOLATION refuses the landing. A gate that COULD NOT RUN examined nothing, and while the substrate is
# declaredly unstable every GPU gate is in that state, so that count is ratcheted instead: it may fall and
# may not rise, and it reaches zero when docs/PHYSICS_TODO.md E does.
LINT_OUT="$(cd "$LANE_WT" && LA_CEILING_STRICT=1 LA_INTEGRATE_BRANCH="$BRANCH" LA_INTEGRATE_SOURCE="$BRANCH" \
	"$LANE_LINT" lint 2>&1)"
LINT_RC=$?
if [ "$LINT_RC" -ne 0 ]; then
	SUMMARY="$(printf '%s\n' "$LINT_OUT" | rg -N -o -e 'LINT_SUMMARY: ([0-9]+) gate\(s\) COULD NOT RUN, ([0-9]+) violation' -r '$1 $2' | head -1)"
	CANNOT="${SUMMARY%% *}"
	VIOL="${SUMMARY##* }"
	UNRUN_CEIL="$(rg -N -o '^[0-9]+$' "$LANE_WT/docs/UNRUNNABLE_GATES_CEILING" 2>/dev/null | head -1)"
	if [ -z "$SUMMARY" ] || [ -z "$UNRUN_CEIL" ] || [ "${VIOL:-1}" -ne 0 ] || [ "${CANNOT:-1}" -gt "$UNRUN_CEIL" ]; then
		echo "integrate: LINT FAILED. $DEV is untouched." >&2
		printf '%s\n' "$LINT_OUT" | rg -N -e '^LINT_FAIL:|^LINT_UNRUNNABLE:|^LAUNCH_COUNT=' | sed 's/^/           /' >&2
		[ -n "$SUMMARY" ] && echo "           $CANNOT could not run (ceiling $UNRUN_CEIL), $VIOL violation(s)." >&2
		echo "           Reproduce with: cd $LANE_WT && scripts/agent_harness.sh lint" >&2
		exit 1
	fi
	echo "integrate: landing with $CANNOT gate(s) that COULD NOT RUN (ceiling $UNRUN_CEIL), 0 violations." >&2
fi

# --- 4. LAND, THEN PRUNE EVERYTHING THIS TOUCHED -------------------------------------------------------
git -C "$ROOT" merge --no-ff "$BRANCH" -m "$SUBJECT" >/dev/null 2>&1 || {
	echo "integrate: $DEV moved under this run. Re-run." >&2; exit 1; }
# The PRIMARY has just moved, so its .godot is stale: a new class_name is unregistered and a new .glsl
# unimported, which makes check_parse_all red and a GPU field silently dead. Its bin is stale the same
# way: the lane's bin was linted against the tree that landed, so it is the one every tree copies next.
# A LANE'S BIN IS COPIED ONLY WHEN IT WAS BUILT FROM THE SOURCES THAT LANDED; otherwise the primary
# builds its own, or every launch from it is refused as stale.
BIN_REL="addons/local_agents/gdextensions/localagents/bin"
. "$SCRIPT_DIR/lib_godot.sh"
LANDED_HASH="$(la_extension_hash "$ROOT")"
LANE_HASH="$(cat "$LANE_WT/$BIN_REL/SOURCE_HASH" 2>/dev/null || echo "")"
if [ -d "$LANE_WT/$BIN_REL" ] && [ ! -L "$LANE_WT/$BIN_REL" ] && [ "$LANE_HASH" = "$LANDED_HASH" ]; then
	rm -rf "$ROOT/$BIN_REL" && cp -R "$LANE_WT/$BIN_REL" "$ROOT/$BIN_REL"
elif [ "$(cat "$ROOT/$BIN_REL/SOURCE_HASH" 2>/dev/null || echo "")" != "$LANDED_HASH" ]; then
	echo "integrate: the primary's bin does not match the landed sources; building." >&2
	"$ROOT/addons/local_agents/gdextensions/localagents/scripts/build_extension.sh" --platform macos >/dev/null 2>&1 \
		|| echo "integrate: build_extension.sh FAILED; every launch from the primary is refused until it is rebuilt." >&2
fi
"$ROOT/scripts/godot_import.sh" "$ROOT" || true
"$ROOT/scripts/editor_scan.sh" --path "$ROOT" >/dev/null 2>&1 || \
	echo "integrate: the post-merge editor scan was not clean; run scripts/editor_scan.sh." >&2
for wt in $(git -C "$ROOT" worktree list --porcelain | rg -N '^worktree ' | sed 's/^worktree //'); do
	[ "$wt" = "$PRIMARY" ] && continue
	[ "$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)" = "$BRANCH" ] || continue
	git -C "$ROOT" worktree remove "$wt" --force >/dev/null 2>&1 || true
done
git -C "$ROOT" branch -D "$BRANCH" >/dev/null 2>&1 || true
echo "integrate: landed on $DEV, and $BRANCH is pruned." >&2
