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
	la_lock_note_freed "$LA_GPU_LOCK_DIR"
	unset LA_GPU_LOCK_HELD
}

# THE ONE ORDERING RULE, DECLARED HERE AND NOWHERE ELSE: the extension lock is taken FIRST and the GPU
# lock LAST. A caller holding the GPU lock that then asks for the extension lock waits on a holder that is
# waiting on it. LA_LOCKS_HELD is exported, so a launch inside a wrapper sees what the wrapper holds.
LA_LOCK_EXT_NAME="$(basename "$GODOT_LOCK_DIR")"
LA_LOCK_GPU_NAME="$(basename "$LA_GPU_LOCK_DIR")"

la_lock_rank() {
	case "$1" in
		"$LA_LOCK_EXT_NAME") printf '0' ;;
		"$LA_LOCK_GPU_NAME") printf '1' ;;
		*) printf -- '-1' ;;
	esac
}

# 0 the order holds · 1 taking <lock> would invert it. Every caller of the machine locks asks through here.
la_lock_order_ok() {
	local want name r_want r_held
	want="$(basename "$1")"
	r_want="$(la_lock_rank "$want")"
	[ "$r_want" -lt 0 ] && return 0
	for name in ${LA_LOCKS_HELD:-}; do
		r_held="$(la_lock_rank "$name")"
		[ "$r_held" -lt 0 ] && continue
		if [ "$r_held" -gt "$r_want" ]; then
			echo "LOCK_ORDER_INVERSION={\"taking\":\"$want\",\"holding\":\"$name\"}" >&2
			echo "  The extension lock is taken FIRST and the GPU lock LAST. Take $want before $name," >&2
			echo "  or release $name first. This process asked for them the other way round." >&2
			return 1
		fi
	done
	return 0
}

la_lock_note_held() {
	LA_LOCKS_HELD="${LA_LOCKS_HELD:-} $(basename "$1")"
	export LA_LOCKS_HELD
}

la_lock_note_freed() {
	local gone out="" x
	gone="$(basename "$1")"
	for x in ${LA_LOCKS_HELD:-}; do
		[ "$x" = "$gone" ] || out="$out $x"
	done
	LA_LOCKS_HELD="$out"
	export LA_LOCKS_HELD
}

# la_dir_lock <path> <timeout_s> <poll_s>. The lock is a symlink whose target is the owner's pid: one
# atomic create carries the owner, so an ownerless lock cannot exist, and a dead owner's is reclaimed.
# `$$` NAMES THE SHELL, NOT THE SUBSHELL: it is the pid that outlives every subshell the lock may be
# taken in, and a recorded owner must be alive for as long as the lock is held or a waiter reclaims it.
#
# A QUEUE IN TWO TIERS, NOT A RACE. Every waiter takes a numbered ticket -- the lowest free number in its
# tier, claimed by the same atomic symlink -- and only the oldest live ticket may take the lock. A retry
# loop over a free lock is decided by who happens to poll first, so a lane can wait out a whole timeout
# while later arrivals keep winning. `LA_LOCK_PRIORITY=1` queues in the tier that is served first, FIFO
# inside each tier: under several lanes the integrator's gates starved and hit their own timeouts. The
# ticket is held until release, or the holder freeing its number would let a newcomer overtake the queue.
# EXIT 0 held · 1 timed out · 3 refused: taking it would invert the lock order.
la_dir_queue_dir() { printf '%s' "$1.q"; }

# Our own tickets in <lock>'s queue, dropped. Called on release: a ticket nobody waits behind blocks
# every later arrival until its pid dies.
la_dir_unqueue() {
	local q f tier
	q="$(la_dir_queue_dir "$1")"
	for tier in p n; do
		for f in "$q/$tier"/*; do
			[ -L "$f" ] || continue
			[ "$(readlink "$f" 2>/dev/null || echo "")" = "$$" ] && rm -f "$f"
		done
		rmdir "$q/$tier" 2>/dev/null
	done
	rmdir "$q" 2>/dev/null
	return 0
}

# The lowest-numbered live ticket in <queue>/<tier>, or "" when that tier is empty. Reclaims dead ones.
la_dir_head() {
	local q="$1" tier="$2" f n owner best=""
	for f in "$q/$tier"/*; do
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
	local waited=0 owner q tier ticket n head ahead f m
	la_lock_order_ok "$lock" || return 3
	q="$(la_dir_queue_dir "$lock")"
	tier=n
	[ "${LA_LOCK_PRIORITY:-0}" = "1" ] && tier=p
	mkdir -p "$q/p" "$q/n" 2>/dev/null
	# TAKE A TICKET: one PAST the highest live number in our tier, atomically, carrying our pid. Reusing
	# the lowest FREE number let a newcomer claim a number under a lane already waiting, and that lane
	# never reached the head of its own queue. A number whose owner is dead is reclaimed on the way past.
	n=0
	for f in "$q/$tier"/*; do
		[ -L "$f" ] || continue
		m="${f##*/}"
		case "$m" in "" | *[!0-9]*) continue ;; esac
		owner="$(readlink "$f" 2>/dev/null || echo "")"
		if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; then
			rm -f "$f"
			continue
		fi
		[ "$m" -ge "$n" ] && n=$((m + 1))
	done
	ticket=""
	while [ -z "$ticket" ]; do
		if ln -s "$$" "$q/$tier/$n" 2>/dev/null; then
			ticket="$q/$tier/$n"
			break
		fi
		owner="$(readlink "$q/$tier/$n" 2>/dev/null || echo "")"
		if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; then
			rm -f "$q/$tier/$n"
			continue
		fi
		n=$((n + 1))
	done
	while :; do
		head="$(la_dir_head "$q" "$tier")"
		ahead=""
		[ "$tier" = "n" ] && ahead="$(la_dir_head "$q" p)"
		# A directory here is a lock of the old shape; it is never taken, only reclaimed or waited on.
		if [ "$head" = "$n" ] && [ -z "$ahead" ] && [ ! -d "$lock" ] && ln -s "$$" "$lock" 2>/dev/null; then
			la_lock_note_held "$lock"
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
			rmdir "$q/$tier" "$q" 2>/dev/null
			return 1
		fi
		sleep "$poll"
		waited=$((waited + poll))
	done
}

# godot_lock [timeout_seconds]
godot_lock() {
	la_dir_lock "$GODOT_LOCK_DIR" "${1:-${LA_GODOT_LOCK_TIMEOUT:-900}}" 1
	case $? in
		0) return 0 ;;
		3) echo "godot_lock: refused, it would invert the lock order." >&2; return 3 ;;
		*) echo "godot_lock: timed out waiting for $GODOT_LOCK_DIR" >&2; return 1 ;;
	esac
}

godot_unlock() {
	rm -rf "$GODOT_LOCK_DIR"
	la_dir_unqueue "$GODOT_LOCK_DIR"
	la_lock_note_freed "$GODOT_LOCK_DIR"
}
