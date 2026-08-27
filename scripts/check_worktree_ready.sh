#!/usr/bin/env bash
# A WORKTREE IS HANDED BACK READY OR NOT AT ALL. Each of new_worktree.sh's four load-bearing steps has been
# silently skipped or downgraded to a warning here before.
#
# EXIT 0 all four hold · 1 one does not · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg

WT="$ROOT/scripts/new_worktree.sh"
[ -f "$WT" ] || { echo "check_worktree_ready: MISSING scripts/new_worktree.sh" >&2; exit 2; }

fail=0
say() { echo "check_worktree_ready: $1" >&2; fail=1; }

rg -q -e 'ln -sfn "\$BIN"' "$WT" || say "it no longer symlinks the compiled bin; the extension will not load."
rg -q -e 'ln -sfn "\$DEPS"' "$WT" \
	|| say "it no longer symlinks the fetched thirdparty/; a lane touching extension sources cannot configure CMake."

# The two steps whose failure must END the run. A warning here is the exact shape that shipped a lane
# whose kernels were never imported: the script said "ready" and every number after it was fiction.
rg -q -e 'abort "--import FAILED' "$WT" \
	|| say "a failed --import no longer aborts. Without the import load() returns null and the GPU field is silently dead."
rg -q -e 'abort "editor scan exited' "$WT" \
	|| say "a failed editor scan no longer aborts. A tree that does not parse reports every class_name MISSING."

rg -q -e 'WARN: --import' -e 'WARN: editor scan' "$WT" \
	&& say "a load-bearing step is back to warning instead of aborting."

# And an abort must take the tree with it, or the next session inherits a worktree nobody made on purpose.
rg -q -e 'worktree remove --force "\$WT"' "$WT" \
	|| say "abort no longer removes the half-made worktree."

[ "$fail" -eq 0 ] && echo "check_worktree_ready: OK"
exit "$fail"
