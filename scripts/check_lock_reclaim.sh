#!/usr/bin/env bash
# THE MACHINE-WIDE LOCKS CANNOT BE LEFT OWNERLESS, AND THEY ARE HANDED OUT IN ARRIVAL ORDER. la_dir_lock
# takes a lock in one atomic create that carries the owner's pid, reclaims one whose owner is dead (of
# either shape), waits on a live one, gives it to the OLDEST waiter, serves LA_LOCK_PRIORITY=1 ahead of
# every plain waiter, and refuses a take that would invert the order (extension lock FIRST, GPU lock LAST).
# The waiting scenarios are independent locks and run side by side, each waiting on its waiters' tickets.
# EXIT 0 all hold · 1 one does not · 2 could not run.
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

# A waiter: a fresh process that takes <lock> (polling every <poll> seconds), appends <name> to <order>,
# and frees it. <env> is LA_LOCK_PRIORITY for the waiter.
waiter() {  # waiter <lock> <order file> <name> <poll seconds> [LA_LOCK_PRIORITY]
  LA_LOCK_PRIORITY="${5:-0}" bash -c '
    . "'"$ROOT"'/scripts/lib_godot_lock.sh"
    la_dir_lock "$1" 20 "$4" || exit 1
    echo "$3" >> "$2"
    rm -rf "$1"
    la_dir_unqueue "$1"
  ' _ "$1" "$2" "$3" "$4" &
}

# <count> tickets in <lock>'s queue, in either tier: every waiter started so far has queued.
queued() {  # queued <lock> <count>
  local n=0 i
  for ((i = 0; i < 400; i++)); do
    n="$(ls "$1.q/p" "$1.q/n" 2>/dev/null | grep -c '^[0-9]')"
    [ "$n" -ge "$2" ] && return 0
    sleep 0.05
  done
  return 1
}

# --- a live owner's lock is waited on, never taken -----------------------------------------------------
live_owner() {
  ln -s "$$" "$T/d"
  if la_dir_lock "$T/d" 2 1 2>/dev/null; then echo "a live owner's lock was taken" >&2; return 1; fi
}

# --- ORDERING: the first waiter in the queue is served first -------------------------------------------
# The slow poller queues FIRST and the fast poller SECOND, so a lock handed out by whoever happens to poll
# after the release goes to the fast one. Only a queue gives it to the slow one.
arrival() {
  local order="$T/order_e" got
  : > "$order"
  ln -s "$$" "$T/e"
  waiter "$T/e" "$order" slow 2
  queued "$T/e" 1 || return 1
  waiter "$T/e" "$order" fast 1
  queued "$T/e" 2 || return 1
  sleep 0.5
  rm -rf "$T/e"
  la_dir_unqueue "$T/e"
  wait
  got="$(tr '\n' ' ' < "$order" | sed 's/ *$//')"
  if [ "$got" != "slow fast" ]; then
    echo "the lock was handed out in the order \"$got\", not in arrival order \"slow fast\"" >&2
    return 1
  fi
}

# --- NO OVERTAKING: a newcomer may not claim a number under a lane already waiting --------------------
# Ticket 0 is held and then released while `waiting` sits on ticket 1: a newcomer must queue above it.
overtake() {
  local order="$T/order_g" got
  : > "$order"
  ln -s "$$" "$T/g"
  mkdir -p "$T/g.q/p" "$T/g.q/n"
  ln -s "$$" "$T/g.q/n/0"
  waiter "$T/g" "$order" waiting 1
  queued "$T/g" 2 || return 1
  rm -f "$T/g.q/n/0"
  waiter "$T/g" "$order" newcomer 1
  queued "$T/g" 2 || return 1
  sleep 0.5
  rm -rf "$T/g"
  wait
  got="$(tr '\n' ' ' < "$order" | sed 's/ *$//')"
  if [ "$got" != "waiting newcomer" ]; then
    echo "the lock was handed out \"$got\": a newcomer took a freed number under a waiting lane" >&2
    return 1
  fi
}

# --- TIERS: a priority waiter queued LAST is served FIRST ---------------------------------------------
# The priority waiter queues LAST and polls SLOWEST, so nothing but the tier can put it first.
tiers() {
  local order="$T/order_f" got
  : > "$order"
  ln -s "$$" "$T/f"
  waiter "$T/f" "$order" plain1 1 0
  queued "$T/f" 1 || return 1
  waiter "$T/f" "$order" plain2 1 0
  queued "$T/f" 2 || return 1
  waiter "$T/f" "$order" urgent 2 1
  queued "$T/f" 3 || return 1
  sleep 0.5
  rm -rf "$T/f"
  la_dir_unqueue "$T/f"
  wait
  got="$(tr '\n' ' ' < "$order" | sed 's/ *$//')"
  if [ "$got" != "urgent plain1 plain2" ]; then
    echo "the lock was handed out \"$got\", not priority-first then arrival order \"urgent plain1 plain2\"" >&2
    return 1
  fi
}

live_owner & p_live=$!
arrival & p_arrival=$!
overtake & p_overtake=$!
tiers & p_tiers=$!

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

for p in "$p_live" "$p_arrival" "$p_overtake" "$p_tiers"; do
  wait "$p" || fail=1
done

[ "$fail" -eq 0 ] && echo "check_lock_reclaim: OK"
exit $fail
