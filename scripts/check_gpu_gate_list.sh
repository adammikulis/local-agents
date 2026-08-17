#!/usr/bin/env bash
# GPU_GATES in agent_harness.sh names exactly the gates that launch a sim, both ways: a gate that needs a
# GPU and is not listed goes UNRUNNABLE off a GPU-less runner, and one that is listed without needing a GPU
# is a gate quietly excused from CI.
# EXIT 0 clean · 1 the list disagrees with the gates · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
H="$ROOT/scripts/agent_harness.sh"
[ -f "$H" ] || { echo "check_gpu_gate_list: MISSING $H" >&2; exit 2; }

declared="$(rg -N -o -e 'GPU_GATES="[^"]*"' "$H" | head -1 | sed -e 's/GPU_GATES="//' -e 's/"$//')"
[ -n "$declared" ] || { echo "check_gpu_gate_list: no GPU_GATES in $H." >&2; exit 2; }

# ONLY the gates lint runs; the hand-run soaks are not CI's business.
in_lint="$(rg -N -o -e '^[[:space:]]+(gpu_)?gate [a-z_]+' "$H" | rg -N -o -e '[a-z_]+$' | sort -u)"
[ -n "$in_lint" ] || { echo "check_gpu_gate_list: parsed no gate list from $H." >&2; exit 2; }

# A gate needs a GPU when it EXECUTES a run — a quoted \$var path to the runner, not a mention of one.
actual=""
for b in $in_lint; do
	f="$ROOT/scripts/$b.sh"
	[ -f "$f" ] || continue
	if rg -q -e '"\$[A-Za-z_][A-Za-z_0-9]*[^"]*/(run_sim_offscreen|sim_run)\.sh"' "$f"; then
		actual="$actual $b"
	fi
done
[ -n "$actual" ] || { echo "check_gpu_gate_list: no lint gate launches a run — scan found nothing." >&2; exit 2; }

fail=0
for b in $actual; do
	case " $declared " in *" $b "*) ;; *)
		echo "FAIL  $b.sh launches a sim and is not in GPU_GATES, so it goes UNRUNNABLE off a GPU." >&2
		fail=1 ;;
	esac
done
for b in $declared; do
	case " $actual " in *" $b "*) ;; *)
		echo "FAIL  $b.sh is in GPU_GATES but launches no sim — a gate excused from CI for nothing." >&2
		fail=1 ;;
	esac
done

[ "$fail" -eq 0 ] || exit 1
echo "check_gpu_gate_list: OK ($(printf '%s' "$declared" | wc -w | tr -d ' ') gate(s) need a GPU, all declared)"
