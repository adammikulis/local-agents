#!/usr/bin/env bash
# RUNG 4 — CONDUCTION. Heat travels down the temperature gradient and the rock's own decay is the source
# term beside it. Every rock in the table carries uranium, thorium and potassium, so `radiogenic` is
# positive or the row did not run; `geo_grad_pairs` is the gradient it conducts down; and the enthalpy
# stock may not move, because conduction moves heat between cells and makes none.
# EXIT 0 the rung holds · 1 it does not · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_rung.sh"

FRAMES="${LA_RUNG_FRAMES:-8}"
KEYS="radiogenic,geo_grad_pairs,geo_grad_max,energy_run_drift_rel,field_cells"
out="$(la_rung_report 4 "$FRAMES" "$KEYS")"
printf '%s\n' "$out" | grep -E '^(radiogenic|geo_grad_pairs|geo_grad_max|energy_run_drift_rel|field_cells)' || true
la_rung_require "$out" radiogenic geo_grad_pairs geo_grad_max energy_run_drift_rel field_cells || exit 2

rad="$(la_rung_value "$out" radiogenic)"
pairs="$(la_rung_value "$out" geo_grad_pairs)"
grad="$(la_rung_value "$out" geo_grad_max)"
resid="$(la_rung_value "$out" energy_run_drift_rel)"
n="$(la_rung_value "$out" field_cells)"

awk -v rad="$rad" -v pairs="$pairs" -v grad="$grad" -v resid="$resid" -v n="$n" 'BEGIN {
	floor_rel = sqrt(n) / 16777216.0
	fail = 0
	if (!(rad > 0)) { print "The rock deposited no radiogenic heat: the conduction row did not run." > "/dev/stderr"; fail = 1 }
	if (!(pairs > 0)) { print "No solid cell has a cell above it, so there is no gradient to conduct down." > "/dev/stderr"; fail = 1 }
	if (grad != grad) { print "The temperature step across a pair is not a number." > "/dev/stderr"; fail = 1 }
	if (!(resid <= floor_rel && resid >= -floor_rel)) { print "The enthalpy stock moved: conduction is making or losing heat." > "/dev/stderr"; fail = 1 }
	exit fail
}' || {
	echo
	echo "Rung 4 does not hold. Reproduce with: scripts/agent_harness.sh sim --rung=4 --frames $FRAMES"
	exit 1
}
echo "check_rung_conduction: OK"
