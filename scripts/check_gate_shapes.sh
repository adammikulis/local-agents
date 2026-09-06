#!/usr/bin/env bash
# A GATE THAT CANNOT FAIL IS NOT A GATE. Two shapes that silently disarm one:
#   MODE      a shell script committed without the execute bit exits 126 when it is invoked directly --
#             neither a pass nor a failure, and a runner that reads only "not zero" calls it a fail it
#             cannot explain, while one that checks for 1 calls it a pass.
#   SWALLOWED a verdict function whose non-zero return is caught by `|| echo` reports a NOTE and lets the
#             script exit 0. scripts/lib_ceiling.sh's ceiling_slack sat behind exactly that in every
#             caller, so the ratchet's slack half had never failed for anybody.
# EXIT 0 clean · 1 a disarmed gate · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v git >/dev/null 2>&1 || { echo "check_gate_shapes: git absent." >&2; exit 2; }

fail=0

modes="$(git -C "$ROOT" ls-files -s scripts/ | awk '$4 ~ /\.sh$/ {print $1, $4}')"
[ -n "$modes" ] || { echo "check_gate_shapes: git listed no scripts/*.sh." >&2; exit 2; }
notexec="$(printf '%s\n' "$modes" | awk '$1 != "100755" {print "  " $2}')"
if [ -n "$notexec" ]; then
	echo "check_gate_shapes: these are committed without the execute bit, so running one exits 126:" >&2
	printf '%s\n' "$notexec" >&2
	echo "  git update-index --chmod=+x <file>" >&2
	fail=1
fi

# Every verdict a library hands back must reach the exit status. `|| echo`, `|| true` and a swallowed
# stderr all turn one into a comment.
VERDICT='ceiling_slack'
swallowed="$(git -C "$ROOT" grep -n -E "(^|[^_[:alnum:]])($VERDICT)[^|]*(\|\|[[:space:]]*(echo|true|:)|2>/dev/null)" -- 'scripts/check_*.sh' || true)"
if [ -n "$swallowed" ]; then
	echo "check_gate_shapes: a verdict is caught and turned into a note:" >&2
	printf '%s\n' "$swallowed" | sed 's/^/  /' >&2
	echo "  Let it decide the exit status: <verdict> ... || exit 1" >&2
	fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "check_gate_shapes: OK"
