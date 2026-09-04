#!/usr/bin/env bash
# ONE QUEUED GATE, RUN AND TIMED. The drain calls this per index; xargs -P calls it for the pool.
# The gate's rc lands in <idx>.rc LAST, so that file appearing means the output beside it is complete.
#   lint_gate_run.sh [--stream] <queue_dir> <index>
# --stream sends the gate's output to this process's stdout instead of <idx>.out, for a gate the drain
# runs in place. EXIT is always 0: the gate's own verdict is the file, not this script's status.
set -uo pipefail

STREAM=0
if [ "${1:-}" = "--stream" ]; then STREAM=1; shift; fi
DIR="${1:?lint_gate_run: no queue directory}"
IDX="${2:?lint_gate_run: no index}"

line="$(awk -F'\t' -v i="$IDX" '$1 == i { print; exit }' "$DIR/queue.tsv")"
if [ -z "$line" ]; then
	echo "lint_gate_run: no queue entry $IDX" >&2
	printf '0\n' > "$DIR/$IDX.t"
	printf '2\n' > "$DIR/$IDX.rc"
	exit 0
fi
cmd="$(printf '%s' "$line" | cut -f4-)"

TIMEFORMAT='%R'
exec 3>&1
if [ "$STREAM" -eq 1 ]; then
	el="$( { time eval "$cmd" 1>&3 2>&3; } 2>&1 1>&3 )"
	rc=$?
else
	el="$( { time eval "$cmd" >"$DIR/$IDX.out" 2>&1; } 2>&1 1>&3 )"
	rc=$?
fi

printf '%s\n' "$el" > "$DIR/$IDX.t"
printf '%s\n' "$rc" > "$DIR/$IDX.rc"
exit 0
