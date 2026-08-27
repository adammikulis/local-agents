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
# A staging tree holding a COMPLETED merge of both tips is a resolved conflict from a prior run: use it,
# or rebuilding here would destroy the resolution the prior run asked for.
if [ -d "$STAGE_WT" ] \
	&& [ -z "$(git -C "$STAGE_WT" status --porcelain 2>/dev/null)" ] \
	&& git -C "$STAGE_WT" merge-base --is-ancestor "$BRANCH" "$STAGE" 2>/dev/null \
	&& git -C "$STAGE_WT" merge-base --is-ancestor "$DEV" "$STAGE" 2>/dev/null; then
	echo "integrate: reusing the resolved staging merge in $STAGE_WT" >&2
else
	git -C "$ROOT" worktree remove "$STAGE_WT" --force >/dev/null 2>&1 || true
	git -C "$ROOT" branch -D "$STAGE" >/dev/null 2>&1 || true
	# ITS OWN bin, ALWAYS: the staging tree is checked out at $DEV and would otherwise meet the primary's
	# dylib, which may be built from a lane whose native class_names $DEV still declares in GDScript.
	LA_OWN_BIN=1 LA_SCAN_LATER=1 "$SCRIPT_DIR/new_worktree.sh" "$STAGE" "$DEV" >/dev/null \
		|| { echo "integrate: could not stage." >&2; exit 2; }

	if ! git -C "$STAGE_WT" merge --no-ff "$BRANCH" -m "$SUBJECT" >/dev/null 2>&1; then
		echo "integrate: the merge conflicts. Resolve it in $STAGE_WT, then re-run." >&2
		git -C "$STAGE_WT" diff --name-only --diff-filter=U | sed 's/^/    /' >&2
		exit 1
	fi
fi

# SCAN AFTER THE MERGE, NOT BEFORE IT. new_worktree.sh scans when it builds the staging tree, which is off
# the DEV branch -- so a lane's new `class_name` or `.glsl` arrives afterwards and is unregistered. The
# staged lint then fails on "Identifier not declared" for a class the lane correctly added, which reads as
# the lane being broken. Imports first (a new kernel is unimported and load()s as null), then the scan.
"$SCRIPT_DIR/godot_import.sh" "$STAGE_WT" || true
"$SCRIPT_DIR/editor_scan.sh" --path "$STAGE_WT" >/dev/null 2>&1 || {
	echo "integrate: the staged tree does not scan clean after the merge." >&2
	"$SCRIPT_DIR/editor_scan.sh" --path "$STAGE_WT" >&2
	exit 1
}

# The integrator owns the ceilings, so it writes them rather than asking a lane to carry the number.
# THE STAGED TREE'S OWN WRITER, for the same reason the lint step below uses the staged harness. The
# primary's copy is the PRE-MERGE one, so a lane that changes how a ceiling is counted would have the stale
# count banked over its new one.
# A landed lane's declaration lands with it. Pruning the branch and leaving its row standing makes the
# next lane trip on a branch that no longer exists.
STAGE_DECL="$STAGE_WT/docs/OPEN_BRANCHES.md"
if [ -f "$STAGE_DECL" ]; then
	rg -N -v -e "^\| \`$(printf '%s' "$BRANCH" | sed 's/[].[^$\\*\/]/\\&/g')\` \|" "$STAGE_DECL" > "$STAGE_DECL.tmp" \
		&& mv "$STAGE_DECL.tmp" "$STAGE_DECL"
fi

STAGE_CEILINGS="$STAGE_WT/scripts/write_ceilings.sh"
[ -x "$STAGE_CEILINGS" ] || { echo "integrate: the staged tree has no write_ceilings.sh." >&2; exit 2; }
LA_CEILING_STRICT=1 "$STAGE_CEILINGS" "$STAGE_WT" >&2 || true
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

# THE DYLIB MUST MATCH THE SOURCE IT IS ABOUT TO LINT. A lane that changed gdextensions/ ships native
# class_names the staging tree only has after the merge, and the scan below cannot parse the tree until
# the extension it loads is the merged one.
if [ -x "$STAGE_WT/addons/local_agents/gdextensions/localagents/scripts/build_extension.sh" ]; then
	echo "integrate: rebuilding the GDExtension for the merged tree" >&2
	if ! (cd "$STAGE_WT/addons/local_agents/gdextensions/localagents" \
			&& bash scripts/build_extension.sh --platform "$(uname -s | tr 'A-Z' 'a-z' | sed 's/darwin/macos/')" \
			>/dev/null 2>&1); then
		echo "integrate: the merged tree's GDExtension does not build. $DEV is untouched." >&2
		exit 1
	fi
fi
echo "integrate: editor scan on the merged tree" >&2
if ! "$SCRIPT_DIR/editor_scan.sh" --path "$STAGE_WT" >&2; then
	echo "integrate: the merged tree does not parse. $DEV is untouched." >&2
	exit 1
fi

echo "integrate: gates, on the merged tree" >&2
# The STAGING TREE'S OWN harness. $SCRIPT_DIR/agent_harness.sh computes its repo root from its own
# location, so it lints the PRIMARY no matter what the cwd is -- it reported green on the wrong tree and
# landed a red merge. cd is not enough; the path has to be the staged one.
STAGE_LINT="$STAGE_WT/scripts/agent_harness.sh"
[ -x "$STAGE_LINT" ] || { echo "integrate: the staged tree has no harness at $STAGE_LINT." >&2; exit 2; }
# A VIOLATION refuses the landing. A gate that COULD NOT RUN examined nothing, and while the substrate is
# declaredly unstable every GPU gate is in that state, so the count is ratcheted instead: it may fall and
# may not rise. Without this nothing lands until PHYSICS_TODO E is fixed, and the lines diverge past the
# handful of commits a reconciliation can still be read at.
LINT_OUT="$(cd "$STAGE_WT" && LA_CEILING_STRICT=1 LA_INTEGRATE_BRANCH="$STAGE" LA_INTEGRATE_SOURCE="$BRANCH" \
	"$STAGE_LINT" lint 2>&1)"
LINT_RC=$?
if [ "$LINT_RC" -ne 0 ]; then
	SUMMARY="$(printf '%s\n' "$LINT_OUT" | rg -N -o -e 'LINT_SUMMARY: ([0-9]+) gate\(s\) COULD NOT RUN, ([0-9]+) violation' -r '$1 $2' | head -1)"
	CANNOT="${SUMMARY%% *}"
	VIOL="${SUMMARY##* }"
	UNRUN_CEIL="$(rg -N -o '^[0-9]+$' "$STAGE_WT/docs/UNRUNNABLE_GATES_CEILING" 2>/dev/null | head -1)"
	if [ -z "$SUMMARY" ] || [ -z "$UNRUN_CEIL" ] || [ "${VIOL:-1}" -ne 0 ] || [ "${CANNOT:-1}" -gt "$UNRUN_CEIL" ]; then
		echo "integrate: LINT FAILED on the merged tree. $DEV is untouched." >&2
		[ -n "$SUMMARY" ] && echo "           $CANNOT could not run (ceiling $UNRUN_CEIL), $VIOL violation(s)." >&2
		echo "           Reproduce with: cd $STAGE_WT && scripts/agent_harness.sh lint" >&2
		exit 1
	fi
	echo "integrate: landing with $CANNOT gate(s) that COULD NOT RUN (ceiling $UNRUN_CEIL), 0 violations." >&2
	echo "           They measure nothing until docs/PHYSICS_TODO.md E is fixed. This is declared, not passed." >&2
fi

# --- 4. LAND, THEN PRUNE EVERYTHING THIS TOUCHED -------------------------------------------------------
git -C "$ROOT" merge --ff-only "$STAGE" >/dev/null 2>&1 || {
	echo "integrate: $DEV moved under this run. Re-run." >&2; exit 1; }
# The PRIMARY has just fast-forwarded, so its .godot is stale: a new class_name is unregistered and a new
# .glsl unimported, which makes check_parse_all red and a GPU field silently dead. The staging tree got
# this from new_worktree.sh; the primary needs it too.
"$SCRIPT_DIR/godot_import.sh" "$ROOT" || true
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
