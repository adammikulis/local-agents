#!/usr/bin/env bash
# A TRACKER'S SILENCE IS NOT EVIDENCE. This whole reconciliation existed because nothing checked branch
# state: two substrate lines diverged for months with zero patch overlap, and by then every conflict was
# a physics decision rather than a merge.
#
# 1. the dev branch contains main
# 2. every local branch ahead of the dev branch is declared in docs/OPEN_BRANCHES.md
# 3. no declared branch is missing, and none is further ahead or older than the limits
# 4. every worktree maps to a branch, holds no unresolved merge, and has moved inside the age limit
#
# A row marked SUPERSEDED is exempt from the age limit and nothing else: its content is already on the dev
# branch, so there is no reconciliation left, only a worktree for its owner to remove.
#
# Agent and workflow worktree BRANCHES are exempt from declaration, being made and reaped in one session.
# Their TREES are not exempt from 4, which is what catches the ones that were never reaped.
#
# EXIT 0 clean · 1 a violation · 2 the gate could not run.
set -uo pipefail
HERE="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="$ROOT/docs/OPEN_BRANCHES.md"
DEV="${LA_DEV_BRANCH:-0.4-dev}"
MAX_AHEAD="${LA_MAX_AHEAD:-15}"
MAX_AGE_DAYS="${LA_MAX_BRANCH_AGE_DAYS:-7}"

command -v git >/dev/null 2>&1 || { echo "check_branch_integration: git absent." >&2; exit 2; }
[ -f "$REGISTRY" ] || { echo "check_branch_integration: MISSING $REGISTRY" >&2; exit 2; }
git -C "$ROOT" rev-parse --verify -q "$DEV" >/dev/null \
  || { echo "check_branch_integration: no dev branch '$DEV'." >&2; exit 2; }

fail=0

if git -C "$ROOT" rev-parse --verify -q main >/dev/null; then
  if ! git -C "$ROOT" merge-base --is-ancestor main "$DEV"; then
    echo "FAIL  $DEV does not contain main. The dev branch is downstream of the release, always." >&2
    fail=1
  fi
else
  echo "check_branch_integration: no 'main' to check against." >&2
  exit 2
fi

declared="$(grep -oE '`[A-Za-z0-9._/-]+`' "$REGISTRY" | tr -d '`' | sort -u)"
[ -n "$declared" ] || { echo "check_branch_integration: $REGISTRY names no branches." >&2; exit 2; }

now="$(git -C "$ROOT" log -1 --format=%ct "$DEV")"
seen=""
while read -r b; do
  case "$b" in worktree-agent-*|worktree-wf_*|"$DEV") continue ;; esac
  # The two branches of an integrate.sh run IN FLIGHT: the staging branch and the lane being landed.
  # Both are deleted before that run returns, so one surviving is a leak the gate must still catch --
  # which is why this keys on the environment of the run, not on a name pattern. Exempting a PATTERN is
  # how worktree-agent-* accumulated thirty-four branches.
  case "$b" in "${LA_INTEGRATE_BRANCH:-__none__}"|"${LA_INTEGRATE_SOURCE:-__none__}") continue ;; esac
  ahead="$(git -C "$ROOT" rev-list --count "$DEV..$b")"
  [ "$ahead" -eq 0 ] && continue
  seen="$seen $b"
  if ! printf '%s\n' "$declared" | grep -qx "$b"; then
    echo "FAIL  $b is $ahead commit(s) ahead of $DEV and is not declared in docs/OPEN_BRANCHES.md." >&2
    fail=1
    continue
  fi
  if [ "$ahead" -gt "$MAX_AHEAD" ]; then
    echo "FAIL  $b is $ahead ahead of $DEV, past the limit of $MAX_AHEAD. Reconcile it now." >&2
    fail=1
  fi
  grep -qE "^\| \`$b\` \| SUPERSEDED" "$REGISTRY" && continue
  age=$(( (now - $(git -C "$ROOT" log -1 --format=%ct "$b")) / 86400 ))
  if [ "$age" -gt "$MAX_AGE_DAYS" ]; then
    echo "FAIL  $b last moved ${age}d ago, past the limit of ${MAX_AGE_DAYS}d." >&2
    fail=1
  fi
done < <(git -C "$ROOT" branch --format='%(refname:short)')

while read -r d; do
  [ -z "$d" ] && continue
  case "$d" in worktree-agent-*|worktree-wf_*|"$DEV") continue ;; esac
  case "$d" in "${LA_INTEGRATE_BRANCH:-__none__}"|"${LA_INTEGRATE_SOURCE:-__none__}") continue ;; esac
  git -C "$ROOT" rev-parse --verify -q "$d" >/dev/null || continue
  [ "$(git -C "$ROOT" rev-list --count "$DEV..$d")" -eq 0 ] || continue
  printf '%s\n' "$declared" | grep -qx "$d" || continue
  grep -qE "^\`$d\` · |\`$d\`.*safe to delete|safe to delete.*\`$d\`" "$REGISTRY" && continue
  if grep -qE "^\| \`$d\`" "$REGISTRY"; then
    echo "FAIL  $d is declared as open but $DEV already contains it. Delete the branch and its row." >&2
    fail=1
  fi
done < <(printf '%s\n' "$declared")

# 4. Every worktree is live. A session tree is exempt from declaration because it is reaped in the session
# that made it; nothing checked that it WAS reaped, and thirty-four survived one reconciliation. A tree on
# a detached HEAD maps to no branch, and one holding an unresolved merge is a conflict nobody finished.
while read -r wt; do
  [ "$wt" = "$ROOT" ] && continue
  [ -d "$wt" ] || continue
  [ "$wt" = "$HERE" ] && continue
  # --absolute-git-dir: --git-dir is relative to the caller's cwd.
  gitdir="$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || continue
  if [ -e "$gitdir/MERGE_HEAD" ]; then
    echo "FAIL  worktree $wt holds an unresolved merge. Finish it or remove the tree." >&2
    fail=1
  fi
  if ! git -C "$wt" symbolic-ref -q HEAD >/dev/null; then
    echo "FAIL  worktree $wt is on a detached HEAD, so it maps to no branch." >&2
    fail=1
    continue
  fi
  wt_age=$(( (now - $(git -C "$wt" log -1 --format=%ct HEAD)) / 86400 ))
  if [ "$wt_age" -gt "$MAX_AGE_DAYS" ]; then
    echo "FAIL  worktree $wt last moved ${wt_age}d ago, past the limit of ${MAX_AGE_DAYS}d." >&2
    fail=1
  fi
done < <(git -C "$ROOT" worktree list --porcelain | awk '/^worktree /{print $2}')

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "A branch nobody is measuring is a reconciliation nobody has scheduled." >&2
  exit 1
fi
echo "check_branch_integration: OK ($DEV contains main;${seen:- no branches} ahead and declared)"
