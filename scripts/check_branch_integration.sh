#!/usr/bin/env bash
# A TRACKER'S SILENCE IS NOT EVIDENCE. This whole reconciliation existed because nothing checked branch
# state: two substrate lines diverged for months with zero patch overlap, and by then every conflict was
# a physics decision rather than a merge.
#
# 1. the dev branch contains main
# 2. every local branch ahead of the dev branch is declared in docs/OPEN_BRANCHES.md
# 3. no declared branch is missing, and none is further ahead or older than the limits
#
# A row marked SUPERSEDED is exempt from the age limit and nothing else: its content is already on the dev
# branch, so there is no reconciliation left, only a worktree for its owner to remove.
#
# Agent and workflow worktree branches are exempt: they are created and reaped within a session.
#
# EXIT 0 clean · 1 a violation · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="$ROOT/docs/OPEN_BRANCHES.md"
DEV="${LA_DEV_BRANCH:-feature/enthalpy}"
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
  git -C "$ROOT" rev-parse --verify -q "$d" >/dev/null || continue
  [ "$(git -C "$ROOT" rev-list --count "$DEV..$d")" -eq 0 ] || continue
  printf '%s\n' "$declared" | grep -qx "$d" || continue
  grep -qE "^\`$d\` · |\`$d\`.*safe to delete|safe to delete.*\`$d\`" "$REGISTRY" && continue
  if grep -qE "^\| \`$d\`" "$REGISTRY"; then
    echo "FAIL  $d is declared as open but $DEV already contains it. Delete the branch and its row." >&2
    fail=1
  fi
done < <(printf '%s\n' "$declared")

if [ "$fail" -ne 0 ]; then
  echo "" >&2
  echo "A branch nobody is measuring is a reconciliation nobody has scheduled." >&2
  exit 1
fi
echo "check_branch_integration: OK ($DEV contains main;${seen:- no branches} ahead and declared)"
