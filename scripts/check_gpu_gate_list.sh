#!/usr/bin/env bash
# kind = "gpu" in scripts/gates.toml names exactly the gates that launch a sim, both ways: a gate that
# needs a GPU and is not declared goes UNRUNNABLE off a GPU-less runner, and one declared without needing
# a GPU is a gate quietly excused from CI.
# EXIT 0 clean · 1 the list disagrees with the gates · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
require_tool python3
RUNNER="$ROOT/scripts/gate_runner.py"
[ -f "$RUNNER" ] || { echo "check_gpu_gate_list: MISSING $RUNNER" >&2; exit 2; }

LIST="$(python3 "$RUNNER" --list 2>&1)" || {
	echo "check_gpu_gate_list: the runner could not read scripts/gates.toml:" >&2
	printf '%s\n' "$LIST" >&2; exit 2; }

in_lint="$(printf '%s\n' "$LIST" | cut -f1 | sort -u)"
declared="$(printf '%s\n' "$LIST" | awk -F'\t' '$2 == "gpu" { print $1 }' | sort -u | tr '\n' ' ')"
[ -n "$in_lint" ] || { echo "check_gpu_gate_list: gates.toml parsed to no gate." >&2; exit 2; }
[ -n "$declared" ] || { echo "check_gpu_gate_list: gates.toml declares no gpu gate." >&2; exit 2; }

# A gate needs a GPU when it EXECUTES a run — a quoted \$var path to the runner, or the native sim binary —
# or when it READS the shared arm lint_capture.sh records, which only a GPU could have produced.
actual=""
for b in $in_lint; do
	f="$ROOT/scripts/$b.sh"
	[ -f "$f" ] || continue
	if rg -q -e '"\$[A-Za-z_][A-Za-z_0-9]*[^"]*/(run_sim_offscreen|sim_run)\.sh"' "$f" \
		|| rg -q -e '[$][(]la_(report|report_raw|marker|cap_state|cap_front)\b' "$f" \
		|| rg -q -e '/bin/lasim"' "$f"; then
		actual="$actual $b"
	fi
done
[ -n "$actual" ] || { echo "check_gpu_gate_list: no lint gate launches a run — scan found nothing." >&2; exit 2; }

fail=0
for b in $actual; do
	case " $declared " in *" $b "*) ;; *)
		echo "FAIL  $b.sh launches a sim and is not kind=gpu in gates.toml, so it goes UNRUNNABLE off a GPU." >&2
		fail=1 ;;
	esac
done
for b in $declared; do
	case " $actual " in *" $b "*) ;; *)
		echo "FAIL  $b.sh is kind=gpu in gates.toml but launches no sim — a gate excused from CI for nothing." >&2
		fail=1 ;;
	esac
done

[ "$fail" -eq 0 ] || exit 1
echo "check_gpu_gate_list: OK ($(printf '%s' "$declared" | wc -w | tr -d ' ') gate(s) need a GPU, all declared)"
