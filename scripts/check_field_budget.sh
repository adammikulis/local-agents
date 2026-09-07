#!/usr/bin/env bash
# WHAT ONE FIELD STEP COSTS: the worst step of the lint's own slice arm, off its field_ms gauge, against
# docs/FIELD_MS_CEILING. DECISION: the worst step, not a sample and not a mean.
# A body capture is a different world's step and is NOT EXAMINED. Ratchet: may fall, may not rise.
# EXIT 0 at or under the ceiling · 1 over it · 2 nothing was timed · 3 not this arm.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_capture.sh"

CEIL_FILE="$ROOT/docs/FIELD_MS_CEILING"
[ -f "$CEIL_FILE" ] || { echo "check_field_budget: no docs/FIELD_MS_CEILING." >&2; exit 2; }
CEIL="$(grep -v '^#' "$CEIL_FILE" | tr -d '[:space:]')"
case "$CEIL" in
	"" | *[!0-9.]*) echo "check_field_budget: the ceiling carries no number." >&2; exit 2 ;;
esac
# 0 IS NOT A CEILING OF ZERO. It is a ratchet no full lint has banked yet, and a step weighed against
# nothing is unexamined: scripts/write_ceilings.sh sets it from the newest lint's own FIELD_BUDGET line.
if [ "$CEIL" = "0" ]; then
	echo "LINT_NOT_EXAMINED: check_field_budget.sh — docs/FIELD_MS_CEILING is unbanked"
	exit 3
fi

CAP="$(la_cap_dir)" || {
	echo "check_field_budget: no LA_LINT_CAPTURE, so no arm was timed and this examined nothing." >&2
	exit 2
}
ARM="$(la_cap_arm 2>/dev/null || true)"
case "$ARM" in
	*'"slice":null'*)
		echo "LINT_NOT_EXAMINED: check_field_budget.sh weighs a slice step; the capture is a body arm"
		exit 3
		;;
esac
REPORT="$(la_cap_report)" || {
	echo "check_field_budget: the shared arm published no SIM_REPORT, so no step was timed." >&2
	exit 2
}
RUNG="$(la_cap_rung 2>/dev/null || echo "")"
FRAMES="${LA_CAPTURE_FRAMES:-20}"

WORST="$(python3 - "$REPORT" <<'PY'
import json, sys
g = json.load(open(sys.argv[1])).get("gauges", {}).get("field_ms")
if not isinstance(g, dict) or "max" not in g:
    raise SystemExit(0)
print("%.4f" % float(g["max"]))
PY
)"
case "$WORST" in
	"" | *[!0-9.]*)
		echo "check_field_budget: the arm carries no field_ms gauge, so no field step was timed." >&2
		echo "                    A world whose step is not gauged cannot be held to a budget." >&2
		exit 2
		;;
esac
if awk -v w="$WORST" 'BEGIN{exit !(w <= 0)}'; then
	echo "check_field_budget: the worst field step reads $WORST ms, so the field never stepped." >&2
	exit 2
fi

echo "FIELD_BUDGET={\"worst_ms\":$WORST,\"ceiling_ms\":$CEIL,\"rung\":${RUNG:-null},\"frames\":$FRAMES}"
if awk -v w="$WORST" -v c="$CEIL" 'BEGIN{exit !(w <= c)}'; then
	echo "check_field_budget: OK ($WORST ms worst step, ceiling $CEIL)"
	exit 0
fi
echo >&2
echo "The worst field step of the shared arm is $WORST ms, past docs/FIELD_MS_CEILING of $CEIL. Every" >&2
echo "run in the loop pays this per step. Fix the step, never the ceiling." >&2
exit 1
