#!/usr/bin/env bash
# THE MACHINE-WIDE LOCKS CANNOT BE LEFT OWNERLESS. la_dir_lock takes a lock in one atomic create that
# carries the owner's pid, reclaims one whose owner is dead (of either shape), and waits on a live one.
# EXIT 0 all four hold · 1 one does not · 2 could not run.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_godot_lock.sh" || exit 2
T="$(mktemp -d)" || exit 2
trap 'rm -rf "$T"' EXIT
fail=0
mkdir "$T/a"
la_dir_lock "$T/a" 2 1 2>/dev/null && [ "$(readlink "$T/a")" = "$$" ] || { echo "an ownerless directory lock was not reclaimed" >&2; fail=1; }
mkdir "$T/b"; echo 999999 > "$T/b/pid"
la_dir_lock "$T/b" 2 1 2>/dev/null && [ "$(readlink "$T/b")" = "$$" ] || { echo "a dead owner's directory lock was not reclaimed" >&2; fail=1; }
ln -s 999999 "$T/c"
la_dir_lock "$T/c" 2 1 2>/dev/null && [ "$(readlink "$T/c")" = "$$" ] || { echo "a dead owner's lock was not reclaimed" >&2; fail=1; }
ln -s "$$" "$T/d"
if la_dir_lock "$T/d" 2 1 2>/dev/null; then echo "a live owner's lock was taken" >&2; fail=1; fi
[ "$fail" -eq 0 ] && echo "check_lock_reclaim: OK"
exit $fail
