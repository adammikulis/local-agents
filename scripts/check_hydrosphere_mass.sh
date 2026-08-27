#!/usr/bin/env bash
# RUNG 1 — GRAVITY. A BODY HAS AS MUCH WATER AS IT HAS, and the grid does not decide how much: the seeded
# H2O stock, in moles off the conservation rows, against the hydrosphere the body record declares. Read at
# rung 1, the rung whose vertical the flood needs to find a basin at all.
# EXIT 0 the water is the body's own · 1 it is not · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_rung.sh"

TOL="${LA_HYDRO_TOL:-0.0001}"
FRAMES="${LA_HYDRO_FRAMES:-6}"
CONST="$ROOT/addons/local_agents/sim/material/PhysicalConstants.gd"

[ -f "$CONST" ] || { echo "check_hydrosphere_mass: MISSING ${CONST#"$ROOT"/}" >&2; exit 2; }
M_H2O="$(sed -n 's/^const MOLAR_MASS_WATER_KG_MOL: float = \([0-9.eE+-]*\).*/\1/p' "$CONST" | head -1)"
if [ -z "$M_H2O" ]; then
	echo "check_hydrosphere_mass: PhysicalConstants.gd declares no MOLAR_MASS_WATER_KG_MOL, so moles" >&2
	echo "                        cannot be weighed." >&2
	exit 2
fi

out="$(la_rung_report 1 "$FRAMES" "h2o_total,body_seed_hydrosphere_kg")"
rc=$?
moles="$(la_rung_value "$out" h2o_total)"
declared="$(la_rung_value "$out" body_seed_hydrosphere_kg)"
for n in "$moles" "$declared"; do
	printf '%s' "$n" | grep -Eq '^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$' || {
		echo "check_hydrosphere_mass: the run published no numeric h2o_total or hydrosphere declaration" >&2
		echo "                        (sim_run exit $rc), so nothing was weighed." >&2
		printf '%s\n' "$out" | tail -20 >&2
		exit 2
	}
done
if ! awk -v d="$declared" 'BEGIN{exit !(d > 0)}'; then
	echo "check_hydrosphere_mass: the body record declares no hydrosphere, so the seed has no water" >&2
	echo "                        budget to be held to." >&2
	exit 2
fi

reading="$(awk -v m="$moles" -v mm="$M_H2O" -v d="$declared" \
	'BEGIN{k = m * mm; r = (k - d) / d; printf "%.6g %.6g", k, (r < 0 ? -r : r)}')"
KG="${reading% *}"
REL="${reading#* }"
echo "HYDROSPHERE={\"seeded_kg\":$KG,\"declared_kg\":$declared,\"rel\":$REL}"
if awk -v r="$REL" -v t="$TOL" 'BEGIN{exit !(r <= t)}'; then
	echo "check_hydrosphere_mass: OK"
	exit 0
fi
echo >&2
echo "The seeded hydrosphere is not the body's. Water is laid into the basins the terrain gives as a" >&2
echo "partial fill under the free-surface reconstruction, so the amount is the body's own mass and the" >&2
echo "cell size decides only how thin the film is. A cell written brim-full instead makes the ocean as" >&2
echo "deep as a grid cell." >&2
exit 1
