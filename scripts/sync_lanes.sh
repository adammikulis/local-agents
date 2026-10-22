#!/usr/bin/env bash
# MERGES THE DEV BRANCH INTO EVERY LANE WORKTREE THAT CAN TAKE IT CLEANLY. A tree with uncommitted changes
# or a conflicting merge is left exactly as it was; check_branch_drift.sh names it once it passes the limit.
set -uo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_dev_branch.sh"
DEV="$(dev_branch "$ROOT")" || exit 2
PRIMARY="$(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{print $2}' | while IFS= read -r wt; do
	[ "$wt" = "$PRIMARY" ] && continue
	b="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)" || continue
	[ "$b" = "$DEV" ] && continue
	[ -n "$(git -C "$wt" log --oneline "$b..$DEV" 2>/dev/null)" ] || continue
	[ -z "$(git -C "$wt" status --porcelain)" ] || { echo "sync_lanes: $b has uncommitted changes; left."; continue; }
	if git -C "$wt" merge --no-edit -q "$DEV" >/dev/null 2>&1; then
		echo "sync_lanes: $b took $DEV."
	else
		git -C "$wt" merge --abort >/dev/null 2>&1
		echo "sync_lanes: $b conflicts with $DEV; left."
	fi
done
