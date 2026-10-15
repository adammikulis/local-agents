#!/usr/bin/env bash
# RUNG 6 — WATER. One h2o channel changes phase where the enthalpy ladder says it does, and pore water
# evaporates into the air above it. There must be liquid to evaporate and vapour over it; the h2o total
# and the enthalpy stock may not move, because latent heat is a transfer and not a source; and the
# riming pair must have separated charge, or the water rung's own rows did not dispatch.
# EXIT 0 the rung holds · 1 it does not · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_rung.sh"

FRAMES="${LA_RUNG_FRAMES:-8}"
KEYS="h2o_rel_drift,energy_run_drift_rel,vapour_amount,water_liquid_total,charge_gross,field_cells"
out="$(la_rung_report 6 "$FRAMES" "$KEYS")"
printf '%s\n' "$out" | grep -E '^(h2o_rel_drift|energy_run_drift_rel|vapour_amount|water_liquid_total|charge_gross|field_cells)' || true
la_rung_require "$out" h2o_rel_drift energy_run_drift_rel vapour_amount water_liquid_total charge_gross field_cells || exit $?

h2o="$(la_rung_value "$out" h2o_rel_drift)"
resid="$(la_rung_value "$out" energy_run_drift_rel)"
vap="$(la_rung_value "$out" vapour_amount)"
liq="$(la_rung_value "$out" water_liquid_total)"
q="$(la_rung_value "$out" charge_gross)"
n="$(la_rung_value "$out" field_cells)"

awk -v h2o="$h2o" -v resid="$resid" -v vap="$vap" -v liq="$liq" -v q="$q" -v n="$n" 'BEGIN {
	floor_rel = sqrt(n) / 16777216.0
	fail = 0
	if (!(liq > 0)) { print "The world holds no liquid water, so nothing can evaporate off it." > "/dev/stderr"; fail = 1 }
	if (!(vap > 0)) { print "No h2o is airborne: nothing crossed the vapour boundary." > "/dev/stderr"; fail = 1 }
	if (!(h2o <= floor_rel && h2o >= -floor_rel)) { print "The h2o total did not hold across a phase change." > "/dev/stderr"; fail = 1 }
	if (!(resid <= floor_rel && resid >= -floor_rel)) { print "The enthalpy stock moved: latent heat is being created or lost." > "/dev/stderr"; fail = 1 }
	if (!(q > 0)) { print "No charge was separated: the riming pair did not run." > "/dev/stderr"; fail = 1 }
	exit fail
}' || {
	echo
	echo "Rung 6 does not hold. Reproduce with: scripts/agent_harness.sh sim --rung=6 --frames $FRAMES"
	exit 1
}
echo "check_rung_water: OK"
