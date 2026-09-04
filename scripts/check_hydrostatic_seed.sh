#!/usr/bin/env bash
# RUNG 2 — HYDROSTATIC. PRESSURE MAY NOT FALL AS YOU GO DOWN, on the sphere, in the world the seed handed
# over. Read at rung 2, so the rows are this rung's own and nothing above it has moved a cell. An audited
# count of zero is an instrument that examined nothing, never a pass.
# EXIT 0 the seeded field is monotone · 1 it is not · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_rung.sh"

FRAMES="${LA_HYDROSTATIC_FRAMES:-6}"
KEYS="pressure_inversions,pressure_audited,pressure_empty,pressure_rest_rel,derive_unconverged_cells,pressure_inv_open,pressure_inv_rock,pressure_inv_surface,pressure_aud_open,pressure_aud_rock,pressure_aud_surface"

out="$(la_rung_report 2 "$FRAMES" "$KEYS")"
rc=$?
la_rung_require "$out" pressure_inversions pressure_audited pressure_empty pressure_rest_rel derive_unconverged_cells || exit 2

# AT REST MEANS THE DERIVE IS A FIXED POINT OF THE SEED: with nothing moving, an open cell's own EOS pressure
# may drift from its first reading by no more than the solve's stopping tolerance per frame
# (state_derive.glsl LA_STATE_TOL), and no cell may exhaust the solve's budget.
rest="$(la_rung_value "$out" pressure_rest_rel)"
unc="$(la_rung_max "$out" derive_unconverged_cells)"
printf 'HYDROSTATIC_REST={"pressure_rest_rel":%s,"derive_unconverged_cells":%s}\n' "$rest" "$unc"
if ! awk -v r="$rest" -v u="$unc" -v n="$FRAMES" 'BEGIN{exit !(r <= n * 1.0e-6 && u == 0)}'; then
	echo "check_hydrostatic_seed: the seeded world is not at rest: an open cell's EOS pressure moves with no" >&2
	echo "                        matter moving, or the (T, p) solve ran out of budget somewhere." >&2
	echo "Reproduce with: scripts/sim_run.sh --rung 2 --frames $FRAMES --report pressure_rest_rel,derive_unconverged_cells" >&2
	exit 1
fi

inv="$(la_rung_value "$out" pressure_inversions)"
aud="$(la_rung_value "$out" pressure_audited)"
# Pairs the emptiness floor kept out. A cell state_derive.glsl gives no bulk state has no pressure, so
# comparing one is comparing a reading with a quantity the model does not define.
empty="$(la_rung_value "$out" pressure_empty)"
printf 'HYDROSTATIC_SEED={"inversions":%s,"audited":%s,"empty":%s,"open":%s/%s,"rock":%s/%s,"surface":%s/%s}\n' \
	"$inv" "$aud" "$empty" \
	"$(la_rung_value "$out" pressure_inv_open)" "$(la_rung_value "$out" pressure_aud_open)" \
	"$(la_rung_value "$out" pressure_inv_rock)" "$(la_rung_value "$out" pressure_aud_rock)" \
	"$(la_rung_value "$out" pressure_inv_surface)" "$(la_rung_value "$out" pressure_aud_surface)"

if ! awk -v a="$aud" 'BEGIN{exit !(a > 0)}'; then
	echo "check_hydrostatic_seed: the audit examined no vertical pair, so it asserts nothing about the" >&2
	echo "                        seeded field. Its own gate kept every pair out (sim_run exit $rc)." >&2
	exit 2
fi
if awk -v i="$inv" 'BEGIN{exit !(i == 0)}'; then
	echo "check_hydrostatic_seed: OK"
	exit 0
fi
echo >&2
echo "Pressure falls going down in the world the seed handed over. The balance the stepper holds is a" >&2
echo "relation on all six faces at once — face_p() on one side against face_p() on the other — so a seed" >&2
echo "that satisfies it only along one axis leaves the rest of the sphere inverted." >&2
exit 1
