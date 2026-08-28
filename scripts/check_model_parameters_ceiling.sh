#!/usr/bin/env bash
# Every constant standing where physics has a relation is a defect; this count may only fall.
# EXIT 0 at or under the ceiling · 1 above it · 2 cannot run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
REG="$ROOT/docs/MODEL_PARAMETERS.md"; CEIL_F="$ROOT/docs/MODEL_PARAMETERS_CEILING"
[ -f "$REG" ] && [ -f "$CEIL_F" ] || { echo "check_model_parameters_ceiling: registry or ceiling missing" >&2; exit 2; }
CEIL="$(rg -N -o '^[0-9]+$' "$CEIL_F" | head -1)"
N="$(rg -ci 'chosen|fitted|clamp|floor|per.step' "$REG")"
echo "MODEL_PARAMETERS_UNDERIVED={\"rows\":$N,\"ceiling\":$CEIL}"
if [ "$N" -gt "$CEIL" ]; then
	echo "FAIL  $N rows of $REG are chosen, fitted, a clamp, a floor or a per-step rate, past the ceiling of $CEIL." >&2
	echo "      A constant where physics has a relation is a defect: write the law of the field it depends on, or cite the measurement." >&2
	exit 1
fi
echo "check_model_parameters_ceiling: OK ($N against $CEIL; the goal is 0)"
