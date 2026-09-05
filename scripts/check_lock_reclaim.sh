#!/usr/bin/env bash
# THE MACHINE-WIDE LOCKS CANNOT BE LEFT OWNERLESS, AND THEY ARE HANDED OUT IN ARRIVAL ORDER. la_dir_lock
# takes a lock in one atomic create that carries the owner's pid, reclaims one whose owner is dead (of
# either shape), waits on a live one, and gives it to the OLDEST waiter -- not to whoever polls first.
# EXIT 0 all five hold · 1 one does not · 2 could not run.
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

# --- ORDERING: the first waiter in the queue is served first -------------------------------------------
# The slow poller queues FIRST and the fast poller SECOND, so a lock handed out by whoever happens to poll
# after the release goes to the fast one. Only a queue gives it to the slow one.
ORDER="$T/order"
: > "$ORDER"
ln -s "$$" "$T/e"
waiter() {  # waiter <name> <poll seconds>
  bash -c '
    . "'"$ROOT"'/scripts/lib_godot_lock.sh"
    la_dir_lock "'"$T"'/e" 40 "$2" || exit 1
    echo "$1" >> "'"$ORDER"'"
    rm -rf "'"$T"'/e"
    la_dir_unqueue "'"$T"'/e"
  ' _ "$1" "$2" &
}
waiter slow 3
sleep 1
waiter fast 1
sleep 1
rm -rf "$T/e"
la_dir_unqueue "$T/e"
wait
GOT="$(tr '\n' ' ' < "$ORDER" | sed 's/ *$//')"
if [ "$GOT" != "slow fast" ]; then
  echo "the lock was handed out in the order \"$GOT\", not in arrival order \"slow fast\"" >&2
  fail=1
fi

[ "$fail" -eq 0 ] && echo "check_lock_reclaim: OK"
exit $fail
