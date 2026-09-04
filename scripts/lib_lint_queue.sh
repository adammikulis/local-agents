#!/usr/bin/env bash
# THE LINT QUEUE. Every gate is enqueued in source order, then drained: a gate that can start an engine
# runs in place and alone, every other gate runs in a bounded worker pool. Output is replayed in enqueue
# order, so the log is byte-for-byte the one a serial arm prints, and each gate's wall seconds are kept.
# The caller supplies la_lq_account <label> <rc>; the drain calls it once per gate, in order.

LA_LQ_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LA_LQ_DIR=""
LA_LQ_N=0
LA_LQ_LABEL=()
LA_LQ_SERIAL=()

la_lq_jobs() {
	local n
	if [ -n "${LA_LINT_JOBS:-}" ]; then printf '%s' "$LA_LINT_JOBS"; return; fi
	n="$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)"
	case "$n" in ''|*[!0-9]*) n=4 ;; esac
	# The gates are ripgrep-bound and rg threads itself, so more workers than this only thrashes.
	[ "$n" -gt 8 ] && n=8
	printf '%s' "$n"
}

la_lq_init() {
	LA_LQ_DIR="$(mktemp -d "${TMPDIR:-/tmp}/la_lint_queue.XXXXXX")" || return 2
	LA_LQ_N=0
	LA_LQ_LABEL=()
	LA_LQ_SERIAL=()
	: > "$LA_LQ_DIR/queue.tsv"
	: > "$LA_LQ_DIR/timing.tsv"
	# git refreshes the index as a side effect of a read, and that write takes .git/index.lock, which a
	# second reader then cannot get. Off, the same comparison happens in core and the cache is not updated;
	# what a gate reports is unchanged, because a diff is decided by content and never by the stat cache.
	export GIT_OPTIONAL_LOCKS=0
}

la_lq_cleanup() {
	[ -n "$LA_LQ_DIR" ] && rm -rf "$LA_LQ_DIR"
	LA_LQ_DIR=""
}

# A GATE THAT CAN START AN ENGINE RUNS ALONE. The editor scan, the import and the GPU each serialise on
# their own lock, and two headless engines over one project's .godot segfault.
# A GATE THAT READS THIS RUN'S OWN LEDGER RUNS ALONE TOO, in its enqueued place: the launch log is written
# by the gates before it, and a pool worker would read it half-written.
la_lq_is_serial() {
	local a
	for a in "$@"; do
		case "$a" in
			*.sh)
				[ -f "$a" ] || continue
				grep -qE 'la_godot|run_sim_offscreen|sim_run\.sh|godot_import|editor_scan|lib_capture|lib_rung|LA_LAUNCH_LOG' \
					"$a" && return 0
				;;
		esac
	done
	return 1
}

# $1 label, then the gate's argv.
la_lq_add() {
	local label="$1"
	shift
	local serial=0
	la_lq_is_serial "$@" && serial=1
	printf '%s\t%s\t%s\t%s\n' "$LA_LQ_N" "$serial" "$label" "$(printf '%q ' "$@")" >> "$LA_LQ_DIR/queue.tsv"
	LA_LQ_LABEL[$LA_LQ_N]="$label"
	LA_LQ_SERIAL[$LA_LQ_N]="$serial"
	LA_LQ_N=$((LA_LQ_N + 1))
}

# A line the queue prints in its own place, for a gate this arm does not run.
la_lq_note() {
	la_lq_add "$1" printf '%s\n' "$2"
}

la_lq_await() {
	local idx="$1"
	while [ ! -f "$LA_LQ_DIR/$idx.rc" ]; do
		if [ -f "$LA_LQ_DIR/POOL_DONE" ]; then
			[ -f "$LA_LQ_DIR/$idx.rc" ] && return 0
			return 1
		fi
		sleep 0.05
	done
	return 0
}

la_lq_drain() {
	local i rc el pool=""
	i=0
	while [ "$i" -lt "$LA_LQ_N" ]; do
		[ "${LA_LQ_SERIAL[$i]}" = "0" ] && pool="$pool$i
"
		i=$((i + 1))
	done
	rm -f "$LA_LQ_DIR/POOL_DONE"
	if [ -n "$pool" ]; then
		(
			printf '%s' "$pool" \
				| xargs -P "$(la_lq_jobs)" -n 1 "$LA_LQ_SCRIPTS/lint_gate_run.sh" "$LA_LQ_DIR" >/dev/null 2>&1
			: > "$LA_LQ_DIR/POOL_DONE"
		) &
	else
		: > "$LA_LQ_DIR/POOL_DONE"
	fi

	i=0
	while [ "$i" -lt "$LA_LQ_N" ]; do
		if [ "${LA_LQ_SERIAL[$i]}" = "1" ]; then
			"$LA_LQ_SCRIPTS/lint_gate_run.sh" --stream "$LA_LQ_DIR" "$i"
		else
			if la_lq_await "$i"; then
				[ -f "$LA_LQ_DIR/$i.out" ] && cat "$LA_LQ_DIR/$i.out"
			else
				echo "lint_queue: the worker pool ended without a verdict for ${LA_LQ_LABEL[$i]}." >&2
				printf '0\n' > "$LA_LQ_DIR/$i.t"
				printf '2\n' > "$LA_LQ_DIR/$i.rc"
			fi
		fi
		rc="$(cat "$LA_LQ_DIR/$i.rc" 2>/dev/null)"
		el="$(cat "$LA_LQ_DIR/$i.t" 2>/dev/null)"
		printf '%s\t%s\n' "${el:-0}" "${LA_LQ_LABEL[$i]}" >> "$LA_LQ_DIR/timing.tsv"
		la_lq_account "${LA_LQ_LABEL[$i]}" "${rc:-2}"
		i=$((i + 1))
	done
	wait 2>/dev/null
	return 0
}

# Every gate's wall seconds, longest first. $1 names the marker.
la_lq_timing() {
	[ -s "$LA_LQ_DIR/timing.tsv" ] || return 0
	sort -rn -k1,1 "$LA_LQ_DIR/timing.tsv" | awk -F'\t' -v marker="${1:-LINT_TIMING}" '
		BEGIN { printf "%s={", marker }
		{ gsub(/"/, "", $2); printf "%s\"%s\":%s", (NR > 1 ? "," : ""), $2, ($1 == "" ? "0" : $1) }
		END { print "}" }'
}
