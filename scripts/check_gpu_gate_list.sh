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

# A gate that runs a HELPER that launches a sim needs a GPU exactly as much as one that launches it
# itself, so the set of launching scripts is grown to a fixed point before the gates are asked. One scan
# of every script per round, not one process per script.
LAUNCH="run_sim_offscreen|sim_run"
while :; do
	grown=0
	hits="$(rg -l -e "(^|[[:space:]]|\()\"\\\$[A-Za-z_][A-Za-z_0-9]*[^\"]*/($LAUNCH)\\.sh\"" "$ROOT"/scripts/*.sh 2>/dev/null)"
	for f in $hits; do
		b="${f##*/}"; b="${b%.sh}"
		case "$b" in lib_*) continue ;; esac   # a library is SOURCED; which of its functions run decides
		case "|$LAUNCH|" in *"|$b|"*) continue ;; esac
		LAUNCH="$LAUNCH|$b"
		grown=1
	done
	[ "$grown" -eq 1 ] || break
done

# A gate needs a GPU when it EXECUTES a run — a quoted \$var path to a launching script, the native sim
# binary, or a lib function that starts either — when it READS the shared arm lint_capture.sh records,
# which only a GPU could produce, or when it weighs the slow tier's timings (`$3 == "slow"`).
CAP_READ='report|report_raw|marker|cap_state|cap_front|cap_report|body_report|cap_life_log|cap_life|rig|shot_arm'
files=()
for b in $in_lint; do
	f="$ROOT/scripts/$b.sh"
	[ -f "$f" ] || continue
	[ "$b" = "check_gpu_gate_list" ] && continue   # this scan names the patterns it looks for
	files+=("$f")
done
actual=""
if [ "${#files[@]}" -gt 0 ]; then
	hits="$(rg -l -e "(^|[[:space:]]|\()\"\\\$[A-Za-z_][A-Za-z_0-9]*[^\"]*/($LAUNCH)\\.sh\"" \
		-e "[\$][(]la_($CAP_READ)\b" \
		-e '[$]3 == "slow"' \
		-e '/bin/lasim"' \
		-e '\bla_lasim(_oracle_run)?\b' "${files[@]}" 2>/dev/null)"
	for f in $hits; do
		b="${f##*/}"
		actual="$actual ${b%.sh}"
	done
fi
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
