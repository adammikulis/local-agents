#!/usr/bin/env bash
# MACHINE-WIDE lock for any godot start-up that loads every GDExtension: `--import` and `--editor`.
#
# The editor-scan lock was per-project, and every lane runs in its own worktree, so it excluded nothing
# across lanes. `--import` took no lock at all from seven call sites. Both load the same native libraries,
# so the race is over the MACHINE, not over one project's .godot -- the same reasoning that makes the GPU
# lock in run_sim_offscreen.sh machine-wide.
#
# mkdir is the portable primitive (macOS has no flock(1)); a lock whose owner died is reclaimed.

GODOT_LOCK_DIR="${TMPDIR:-/tmp}/la_godot_extension.lock"

# ONE GPU ON THIS MACHINE, AND EVERY START-UP CAN MAKE A RenderingDevice — a rig probe and a headless
# batch as much as a sim. So the lock belongs to the LAUNCH, not to one wrapper: several lanes' engines
# on one GPU push a sim past Godot's own fence wait, which it reports as an engine error.
# Reentrant through an exported marker, so a wrapper holding it for a whole run is not blocked by the
# launch inside it. Ordering, everywhere: the extension lock is taken FIRST and the GPU lock LAST.
LA_GPU_LOCK_DIR="${TMPDIR:-/tmp}/la_sim_gpu.lock"

# 0 this caller now holds it · 1 timed out · 2 this process tree already holds it.
la_gpu_lock() {
	[ "${LA_GPU_LOCK_HELD:-0}" = "1" ] && return 2
	la_dir_lock "$LA_GPU_LOCK_DIR" "${LA_SIM_LOCK_TIMEOUT:-1800}" 2 || return 1
	export LA_GPU_LOCK_HELD=1
	return 0
}

la_gpu_unlock() {
	rm -rf "$LA_GPU_LOCK_DIR"
	la_dir_unqueue "$LA_GPU_LOCK_DIR"
	unset LA_GPU_LOCK_HELD
}

# la_dir_lock <path> <timeout_s> <poll_s>. The lock is a symlink whose target is the owner's pid: one
# atomic create carries the owner, so an ownerless lock cannot exist, and a dead owner's is reclaimed.
# `$$` NAMES THE SHELL, NOT THE SUBSHELL: it is the pid that outlives every subshell the lock may be
# taken in, and a recorded owner must be alive for as long as the lock is held or a waiter reclaims it
# out from under the holder.
#
# A FIRST-COME QUEUE, NOT A RACE. Every waiter takes a numbered ticket -- the lowest free number, claimed
# by the same atomic symlink -- and only the oldest live ticket may take the lock. A retry loop over a
# free lock is decided by who happens to poll first, so under contention a lane can wait out a whole
# timeout while later arrivals keep winning. The ticket is held until unlock, or the holder's release
# would let a newcomer claim the freed number and overtake everyone already queued.
la_dir_queue_dir() { printf '%s' "$1.q"; }

# Our own ticket in <lock>'s queue, dropped. Called on release and on timeout: a ticket nobody is waiting
# behind blocks every later arrival until its pid dies.
la_dir_unqueue() {
	local q f
	q="$(la_dir_queue_dir "$1")"
	for f in "$q"/*; do
		[ -L "$f" ] || continue
		[ "$(readlink "$f" 2>/dev/null || echo "")" = "$$" ] && rm -f "$f"
	done
	rmdir "$q" 2>/dev/null
	return 0
}

# The lowest-numbered live ticket in <queue>, or "" when the queue is empty. Reclaims dead ones.
la_dir_head() {
	local q="$1" f n owner best=""
	for f in "$q"/*; do
		[ -L "$f" ] || continue
		n="${f##*/}"
		case "$n" in "" | *[!0-9]*) continue ;; esac
		owner="$(readlink "$f" 2>/dev/null || echo "")"
		if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; then
			rm -f "$f"
			continue
		fi
		if [ -z "$best" ] || [ "$n" -lt "$best" ]; then best="$n"; fi
	done
	printf '%s' "$best"
}

la_dir_lock() {
	local lock="$1" timeout="$2" poll="${3:-1}"
	local waited=0 owner q ticket n head
	q="$(la_dir_queue_dir "$lock")"
	mkdir -p "$q" 2>/dev/null
	# TAKE A TICKET: the lowest free number, atomically, carrying our pid. A number whose owner is dead is
	# reclaimed on the way past, so a crashed waiter does not push the queue forward for ever.
	n=0
	ticket=""
	while [ -z "$ticket" ]; do
		if ln -s "$$" "$q/$n" 2>/dev/null; then
			ticket="$q/$n"
			break
		fi
		owner="$(readlink "$q/$n" 2>/dev/null || echo "")"
		if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; then
			rm -f "$q/$n"
			continue
		fi
		n=$((n + 1))
	done
	while :; do
		head="$(la_dir_head "$q")"
		# A directory here is a lock of the old shape; it is never taken, only reclaimed or waited on.
		if [ "$head" = "$n" ] && [ ! -d "$lock" ] && ln -s "$$" "$lock" 2>/dev/null; then
			return 0
		fi
		if [ -e "$lock" ] || [ -L "$lock" ]; then
			owner="$(readlink "$lock" 2>/dev/null || cat "$lock/pid" 2>/dev/null || echo "")"
			if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; then
				echo "$(basename "$lock"): clearing stale lock from dead pid ${owner:-none}" >&2
				rm -rf "$lock"
				continue
			fi
		fi
		if [ "$waited" -ge "$timeout" ]; then
			rm -f "$ticket"
			rmdir "$q" 2>/dev/null
			return 1
		fi
		sleep "$poll"
		waited=$((waited + poll))
	done
}

# godot_lock [timeout_seconds]
godot_lock() {
	la_dir_lock "$GODOT_LOCK_DIR" "${1:-${LA_GODOT_LOCK_TIMEOUT:-900}}" 1 || {
		echo "godot_lock: timed out waiting for $GODOT_LOCK_DIR" >&2
		return 1
	}
}

godot_unlock() {
	rm -rf "$GODOT_LOCK_DIR"
	la_dir_unqueue "$GODOT_LOCK_DIR"
}
