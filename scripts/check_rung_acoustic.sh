#!/usr/bin/env bash
# RUNG 3 — ACOUSTIC. Compressible matter and its momentum advance together on the acoustic substep.
# Nothing drives this world but pressure and gravity, which cancel at balance, so no cell may outrun the
# mixture sound speed the equation of state gives it, nothing may be created carrying that motion, and
# `momentum_cells` must be positive or the group never dispatched and every claim above is vacuous.
# EXIT 0 the rung holds · 1 it does not · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_rung.sh"

FRAMES="${LA_RUNG_FRAMES:-8}"
KEYS="celerity_max,wind_speed_max,momentum_cells,h2o_rel_drift,energy_run_drift_rel,field_cells"
KEYS="$KEYS,energy_stock,energy_kinetic,energy_potential"
out="$(la_rung_report 3 "$FRAMES" "$KEYS")"
printf '%s\n' "$out" | grep -E '^(celerity_max|wind_speed_max|momentum_cells|h2o_rel_drift|energy_run_drift_rel|field_cells|energy_stock|energy_kinetic|energy_potential)' || true
la_rung_require "$out" celerity_max wind_speed_max momentum_cells h2o_rel_drift energy_run_drift_rel field_cells energy_stock energy_kinetic energy_potential || exit 2


cel="$(la_rung_value "$out" celerity_max)"
wind="$(la_rung_value "$out" wind_speed_max)"
cells="$(la_rung_value "$out" momentum_cells)"
h2o="$(la_rung_value "$out" h2o_rel_drift)"
resid="$(la_rung_value "$out" energy_run_drift_rel)"
n="$(la_rung_value "$out" field_cells)"

awk -v cel="$cel" -v wind="$wind" -v cells="$cells" -v h2o="$h2o" -v resid="$resid" -v n="$n" 'BEGIN {
	floor_rel = sqrt(n) / 16777216.0
	fail = 0
	if (!(cel > 0)) { print "The mixture has no sound speed, so nothing here is compressible." > "/dev/stderr"; fail = 1 }
	if (wind > cel) { print "A cell is moving faster than its own sound speed." > "/dev/stderr"; fail = 1 }
	if (!(cells > 0)) { print "No open cell carries motion: the acoustic group never moved anything." > "/dev/stderr"; fail = 1 }
	if (!(h2o <= floor_rel && h2o >= -floor_rel)) { print "The h2o total moved on a box with every wall shut." > "/dev/stderr"; fail = 1 }
	if (!(resid <= floor_rel && resid >= -floor_rel)) { print "The world total of heat, motion and height moved on a box with nothing outside it." > "/dev/stderr"; fail = 1 }
	exit fail
}' || {
	echo
	echo "Rung 3 does not hold. Reproduce with: scripts/agent_harness.sh sim --rung=3 --frames $FRAMES"
	exit 1
}
echo "check_rung_acoustic: OK"
