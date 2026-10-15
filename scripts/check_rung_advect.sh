#!/usr/bin/env bash
# RUNG 5 — ADVECT. Matter is carried by the flow, grains settle through it, and what stands too steep
# slumps. On a box with every wall shut a tracer's total may not move and the momentum book must close
# against the body force it was given; and something must actually have been carried, or no settle row
# put a grain into the air or the water and the arithmetic above is true of a still world.
# EXIT 0 the rung holds · 1 it does not · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_rung.sh"

FRAMES="${LA_RUNG_FRAMES:-8}"
KEYS="h2o_rel_drift,mineral_rel_drift,momentum_run_drift_rel,airborne_mineral_sum,suspended_cells,field_cells"
out="$(la_rung_report 5 "$FRAMES" "$KEYS")"
printf '%s\n' "$out" | grep -E '^(h2o_rel_drift|mineral_rel_drift|momentum_run_drift_rel|airborne_mineral_sum|suspended_cells|field_cells)' || true
la_rung_require "$out" h2o_rel_drift mineral_rel_drift momentum_run_drift_rel airborne_mineral_sum suspended_cells field_cells || exit $?

h2o="$(la_rung_value "$out" h2o_rel_drift)"
min="$(la_rung_value "$out" mineral_rel_drift)"
mom="$(la_rung_value "$out" momentum_run_drift_rel)"
air="$(la_rung_value "$out" airborne_mineral_sum)"
susp="$(la_rung_value "$out" suspended_cells)"
n="$(la_rung_value "$out" field_cells)"

awk -v h2o="$h2o" -v min="$min" -v mom="$mom" -v air="$air" -v susp="$susp" -v n="$n" 'BEGIN {
	floor_rel = sqrt(n) / 16777216.0
	fail = 0
	if (!(h2o <= floor_rel && h2o >= -floor_rel)) { print "The h2o total did not hold on a shut box." > "/dev/stderr"; fail = 1 }
	if (!(min <= floor_rel && min >= -floor_rel)) { print "The mineral total did not hold on a shut box." > "/dev/stderr"; fail = 1 }
	if (!(mom <= floor_rel && mom >= -floor_rel)) { print "The momentum book does not close against the body force it was given." > "/dev/stderr"; fail = 1 }
	if (!(air > 0) && !(susp > 0)) { print "No grain is suspended in air or water: no settle row carried anything." > "/dev/stderr"; fail = 1 }
	exit fail
}' || {
	echo
	echo "Rung 5 does not hold. Reproduce with: scripts/agent_harness.sh sim --rung=5 --frames $FRAMES"
	exit 1
}
echo "check_rung_advect: OK"
