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
[ "$PRIMARY" = "$ROOT" ] || { echo "integrate: run this from the primary checkout ($PRIMARY), not $ROOT." >&2; exit 2; }
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

# --- 3. MERGE AND VERIFY OFF THE DEV BRANCH ------------------------------------------------------------
STAGE="integrate/$(printf '%s' "$BRANCH" | tr '/' '-')"
STAGE_WT="$PRIMARY/../la-$(printf '%s' "$STAGE" | tr '/' '-')"
git -C "$ROOT" worktree remove "$STAGE_WT" --force >/dev/null 2>&1 || true
git -C "$ROOT" branch -D "$STAGE" >/dev/null 2>&1 || true
"$SCRIPT_DIR/new_worktree.sh" "$STAGE" "$DEV" >/dev/null || { echo "integrate: could not stage." >&2; exit 2; }

if ! git -C "$STAGE_WT" merge --no-ff "$BRANCH" -m "$SUBJECT" >/dev/null 2>&1; then
	echo "integrate: the merge conflicts. Resolve it in $STAGE_WT, then re-run." >&2
	git -C "$STAGE_WT" diff --name-only --diff-filter=U | sed 's/^/    /' >&2
	exit 1
fi

# The integrator owns the ceilings, so it writes them rather than asking a lane to carry the number.
LA_CEILING_STRICT=1 "$SCRIPT_DIR/write_ceilings.sh" "$STAGE_WT" >&2 || true
if [ -n "$(git -C "$STAGE_WT" status --porcelain)" ]; then
	git -C "$STAGE_WT" add -A
	# NOT `|| true`. A pre-commit hook can block this, and swallowing that leaves the ceilings unwritten
	# while the run reports success -- which is how a red ratchet reached the dev branch.
	# The staging tree's pre-commit hook runs the full lint, so it needs the same in-flight exemption the
	# gate step gets: without it check_branch_integration fails on the staging branch itself.
	if ! (cd "$STAGE_WT" && LA_CEILING_STRICT=1 LA_INTEGRATE_BRANCH="$STAGE" LA_INTEGRATE_SOURCE="$BRANCH" \
			git commit -q -m "chore(ceilings): the post-merge counts"); then
		echo "integrate: could not commit the ceilings. $DEV is untouched." >&2
		exit 1
	fi
fi

echo "integrate: gates, on the merged tree" >&2
# The STAGING TREE'S OWN harness. $SCRIPT_DIR/agent_harness.sh computes its repo root from its own
# location, so it lints the PRIMARY no matter what the cwd is -- it reported green on the wrong tree and
# landed a red merge. cd is not enough; the path has to be the staged one.
STAGE_LINT="$STAGE_WT/scripts/agent_harness.sh"
[ -x "$STAGE_LINT" ] || { echo "integrate: the staged tree has no harness at $STAGE_LINT." >&2; exit 2; }
if ! (cd "$STAGE_WT" && LA_CEILING_STRICT=1 LA_INTEGRATE_BRANCH="$STAGE" LA_INTEGRATE_SOURCE="$BRANCH" "$STAGE_LINT" lint >/dev/null 2>&1); then
	echo "integrate: LINT FAILED on the merged tree. $DEV is untouched." >&2
	echo "           Reproduce with: cd $STAGE_WT && scripts/agent_harness.sh lint" >&2
	exit 1
fi

# --- 4. LAND, THEN PRUNE EVERYTHING THIS TOUCHED -------------------------------------------------------
git -C "$ROOT" merge --ff-only "$STAGE" >/dev/null 2>&1 || {
	echo "integrate: $DEV moved under this run. Re-run." >&2; exit 1; }
# The PRIMARY has just fast-forwarded, so its .godot is stale: a new class_name is unregistered and a new
# .glsl unimported, which makes check_parse_all red and a GPU field silently dead. The staging tree got
# this from new_worktree.sh; the primary needs it too.
(cd "$ROOT" && godot --headless --path . --import >/dev/null 2>&1) || true
"$SCRIPT_DIR/editor_scan.sh" --path "$ROOT" >/dev/null 2>&1 || \
	echo "integrate: the post-merge editor scan was not clean; run scripts/editor_scan.sh." >&2
git -C "$ROOT" worktree remove "$STAGE_WT" --force >/dev/null 2>&1 || true
git -C "$ROOT" branch -D "$STAGE" >/dev/null 2>&1 || true
for wt in $(git -C "$ROOT" worktree list --porcelain | rg -N '^worktree ' | sed 's/^worktree //'); do
	[ "$wt" = "$PRIMARY" ] && continue
	[ "$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)" = "$BRANCH" ] || continue
	git -C "$ROOT" worktree remove "$wt" --force >/dev/null 2>&1 || true
done
git -C "$ROOT" branch -D "$BRANCH" >/dev/null 2>&1 || true
echo "integrate: landed on $DEV, and $BRANCH is pruned." >&2
