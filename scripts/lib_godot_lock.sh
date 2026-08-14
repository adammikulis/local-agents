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

# godot_lock [timeout_seconds]
godot_lock() {
	local timeout="${1:-${LA_GODOT_LOCK_TIMEOUT:-900}}"
	local waited=0 owner
	until mkdir "$GODOT_LOCK_DIR" 2>/dev/null; do
		if [ -f "$GODOT_LOCK_DIR/pid" ]; then
			owner="$(cat "$GODOT_LOCK_DIR/pid" 2>/dev/null || echo "")"
			if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
				echo "godot_lock: clearing stale lock from dead pid $owner" >&2
				rm -rf "$GODOT_LOCK_DIR"
				continue
			fi
		fi
		if [ "$waited" -ge "$timeout" ]; then
			echo "godot_lock: timed out after ${timeout}s waiting for $GODOT_LOCK_DIR" >&2
			return 1
		fi
		sleep 1
		waited=$((waited + 1))
	done
	echo $$ > "$GODOT_LOCK_DIR/pid"
	return 0
}

godot_unlock() {
	rm -rf "$GODOT_LOCK_DIR"
}
