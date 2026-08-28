#!/usr/bin/env bash
# RUNG 2 — HYDROSTATIC. PRESSURE MAY NOT FALL AS YOU GO DOWN, on the sphere, in the world the seed handed
# over. Read at rung 2, so the rows are this rung's own and nothing above it has moved a cell. An audited
# count of zero is an instrument that examined nothing, never a pass.
# EXIT 0 the seeded field is monotone · 1 it is not · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_rung.sh"

FRAMES="${LA_HYDROSTATIC_FRAMES:-6}"
KEYS="pressure_inversions,pressure_audited,pressure_empty,pressure_inv_open,pressure_inv_rock,pressure_inv_surface,pressure_aud_open,pressure_aud_rock,pressure_aud_surface"

out="$(la_rung_report 2 "$FRAMES" "$KEYS")"
rc=$?
la_rung_require "$out" pressure_inversions pressure_audited pressure_empty || exit 2

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
