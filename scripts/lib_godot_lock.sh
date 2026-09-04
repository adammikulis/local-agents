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

# la_dir_lock <path> <timeout_s> <poll_s>. The lock is a symlink whose target is the owner's pid: one
# atomic create carries the owner, so an ownerless lock cannot exist, and a dead owner's is reclaimed.
la_dir_lock() {
	local lock="$1" timeout="$2" poll="${3:-1}"
	local waited=0 owner
	while :; do
		# A directory here is a lock of the old shape; it is never taken, only reclaimed or waited on.
		if [ ! -d "$lock" ] && ln -s "$$" "$lock" 2>/dev/null; then
			return 0
		fi
		owner="$(readlink "$lock" 2>/dev/null || cat "$lock/pid" 2>/dev/null || echo "")"
		if [ -z "$owner" ] || ! kill -0 "$owner" 2>/dev/null; then
			echo "$(basename "$lock"): clearing stale lock from dead pid ${owner:-none}" >&2
			rm -rf "$lock"
			continue
		fi
		if [ "$waited" -ge "$timeout" ]; then
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
}
