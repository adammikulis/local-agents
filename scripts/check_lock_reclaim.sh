#!/usr/bin/env bash
# THE MACHINE-WIDE LOCKS CANNOT BE LEFT OWNERLESS, AND THEY ARE HANDED OUT IN ARRIVAL ORDER. la_dir_lock
# takes a lock in one atomic create that carries the owner's pid, reclaims one whose owner is dead (of
# either shape), waits on a live one, gives it to the OLDEST waiter -- not to whoever polls first --
# serves LA_LOCK_PRIORITY=1 ahead of every plain waiter, and refuses a take that would invert the order
# (the extension lock FIRST, the GPU lock LAST).
# EXIT 0 all seven hold · 1 one does not · 2 could not run.
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

# --- NO OVERTAKING: a newcomer may not claim a number under a lane already waiting --------------------
# Ticket 0 is held and then released while `waiting` sits on ticket 1: a newcomer must queue above it.
: > "$ORDER"
ln -s "$$" "$T/g"
mkdir -p "$T/g.q/p" "$T/g.q/n"
ln -s "$$" "$T/g.q/n/0"
overtake() {  # overtake <name>
  bash -c '
    . "'"$ROOT"'/scripts/lib_godot_lock.sh"
    la_dir_lock "'"$T"'/g" 40 1 || exit 1
    echo "$1" >> "'"$ORDER"'"
    rm -rf "'"$T"'/g"
    la_dir_unqueue "'"$T"'/g"
  ' _ "$1" &
}
overtake waiting
sleep 2
rm -f "$T/g.q/n/0"
overtake newcomer
sleep 2
rm -rf "$T/g"
wait
GOT="$(tr '\n' ' ' < "$ORDER" | sed 's/ *$//')"
if [ "$GOT" != "waiting newcomer" ]; then
  echo "the lock was handed out \"$GOT\": a newcomer took a freed number under a waiting lane" >&2
  fail=1
fi

# --- TIERS: a priority waiter queued LAST is served FIRST ---------------------------------------------
: > "$ORDER"
ln -s "$$" "$T/f"
# The priority waiter queues LAST and polls SLOWEST, so nothing but the tier can put it first.
tiered() {  # tiered <name> <LA_LOCK_PRIORITY> <poll seconds>
  LA_LOCK_PRIORITY="$2" bash -c '
    . "'"$ROOT"'/scripts/lib_godot_lock.sh"
    la_dir_lock "'"$T"'/f" 60 "$2" || exit 1
    echo "$1" >> "'"$ORDER"'"
    rm -rf "'"$T"'/f"
    la_dir_unqueue "'"$T"'/f"
  ' _ "$1" "$3" &
}
tiered plain1 0 1
sleep 1
tiered plain2 0 1
sleep 1
tiered urgent 1 3
sleep 1
rm -rf "$T/f"
la_dir_unqueue "$T/f"
wait
GOT="$(tr '\n' ' ' < "$ORDER" | sed 's/ *$//')"
if [ "$GOT" != "urgent plain1 plain2" ]; then
  echo "the lock was handed out \"$GOT\", not priority-first then arrival order \"urgent plain1 plain2\"" >&2
  fail=1
fi

# --- ORDER: the GPU lock is taken LAST, so the extension lock may not be taken while it is held --------
# Locks under $T carrying the machine locks' NAMES: la_lock_rank reads the basename, and a gate may not
# reach for a lock another lane is holding.
EXT="$T/$(basename "$GODOT_LOCK_DIR")"
GPU="$T/$(basename "$LA_GPU_LOCK_DIR")"
if LA_LOCKS_HELD="$(basename "$LA_GPU_LOCK_DIR")" la_dir_lock "$EXT" 2 1 2>/dev/null; then
  echo "the extension lock was taken by a caller already holding the GPU lock" >&2
  rm -rf "$EXT"
  fail=1
fi
if ! LA_LOCKS_HELD="$(basename "$GODOT_LOCK_DIR")" la_dir_lock "$GPU" 2 1 2>/dev/null; then
  echo "the GPU lock was refused to a caller holding only the extension lock, which is the right order" >&2
  fail=1
else
  rm -rf "$GPU"
fi

(
  . "$ROOT/scripts/lib_godot.sh"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/launcher_fixture"
  chmod +x "$T/launcher_fixture"
  GODOT="$T/launcher_fixture"
  LA_LAUNCH_LOG="$T/fixture_launches"
  la_agent_exe() { printf '%s' "$GODOT"; }
  la_extension_current() { return 0; }
  consulted=0
  la_gpu_lock() { consulted=$((consulted + 1)); return 1; }
  la_gpu_unlock() { :; }
  if ! LA_CPU_VALIDATION=1 la_godot --headless --version >/dev/null 2>&1 || [ "$consulted" -ne 0 ]; then
    echo "explicit CPU validation queued for the GPU lock" >&2
    exit 1
  fi
  LA_CPU_VALIDATION=0 la_godot --headless --version >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 2 ] || [ "$consulted" -ne 1 ]; then
    echo "headless native work did not require the GPU lock" >&2
    exit 1
  fi
  LA_CPU_VALIDATION=1 la_godot --version >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 2 ] || [ "$consulted" -ne 2 ]; then
    echo "rendered work did not require the GPU lock" >&2
    exit 1
  fi
) || fail=1

[ "$fail" -eq 0 ] && echo "check_lock_reclaim: OK"
exit $fail
