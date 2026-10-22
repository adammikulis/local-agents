#!/usr/bin/env bash
# NO BRANCH OR WORKTREE MAY SIT FAR BEHIND THE DEV BRANCH. A lane that falls behind is merged, landed or
# deleted; docs/BRANCH_DRIFT_LIMIT is the most commits behind any local branch may be, and
# docs/STALE_BRANCH_CEILING is how many may exceed it (a ratchet: it falls, never rises).
# EXIT 0 within the ceiling · 1 a branch drifted · 2 cannot run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_dev_branch.sh"
. "$ROOT/scripts/lib_ceiling.sh" 2>/dev/null || true
DEV="$(dev_branch "$ROOT")" || exit 2
LIMIT="$(rg -N -e '^[0-9]+$' "$ROOT/docs/BRANCH_DRIFT_LIMIT" 2>/dev/null | head -1)"
CEIL="$(rg -N -e '^[0-9]+$' "$ROOT/docs/STALE_BRANCH_CEILING" 2>/dev/null | head -1)"
[ -n "$LIMIT" ] && [ -n "$CEIL" ] || { echo "check_branch_drift: docs/BRANCH_DRIFT_LIMIT or STALE_BRANCH_CEILING carries no number." >&2; exit 2; }
git -C "$ROOT" show-ref --verify --quiet "refs/heads/$DEV" || { echo "check_branch_drift: no branch $DEV." >&2; exit 2; }
stale=0
report=""
while IFS= read -r b; do
	[ "$b" = "$DEV" ] || [ "$b" = "main" ] && continue
	behind="$(git -C "$ROOT" rev-list --count "$b..$DEV")"
	if [ "$behind" -gt "$LIMIT" ]; then
		stale=$((stale + 1))
		report="$report  $b is $behind behind $DEV (limit $LIMIT): merge $DEV into it, land it with scripts/integrate.sh, or delete it.
"
	fi
done < <(git -C "$ROOT" for-each-ref --format='%(refname:short)' refs/heads)
echo "STALE_BRANCHES: $stale"
if [ "$stale" -gt "$CEIL" ]; then
	echo "check_branch_drift: FAILED — $stale branch(es) past the limit, ceiling $CEIL:" >&2
	printf '%s' "$report" >&2
	exit 1
fi
echo "check_branch_drift: OK ($stale stale, ceiling $CEIL)"
