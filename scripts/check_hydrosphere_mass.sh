#!/usr/bin/env bash
# RUNG 1 — GRAVITY. A BODY HAS AS MUCH WATER AS IT HAS, and the grid does not decide how much: the seeded
# H2O stock, in moles off the conservation rows, against the hydrosphere the body record declares. Read at
# rung 1, the rung whose vertical the flood needs to find a basin at all.
# THE ARM IS THE BODY: a box on the surface holds a fraction of the ocean, so on a slice arm this is
# NOT EXAMINED.
# EXIT 0 the water is the body's own · 1 it is not · 2 could not run · 3 the arm was a slice.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_rung.sh"
. "$ROOT/scripts/lib_capture.sh"
la_body_scoped "$(basename "$0")" || exit $?

# THE SEA STANDS WHERE THE SHAPE PUTS IT, read at the grid's own resolution: the quadrature's departure
# is a ratchet, docs/HYDROSPHERE_SEED_REL, never a budget the seed scales to.
CEIL="$ROOT/docs/HYDROSPHERE_SEED_REL"
[ -f "$CEIL" ] || { echo "check_hydrosphere_mass: MISSING ${CEIL#"$ROOT"/}" >&2; exit 2; }
TOL="$(grep -v '^#' "$CEIL" | tr -d '[:space:]')"
FRAMES="${LA_HYDRO_FRAMES:-6}"
CONST="$ROOT/addons/local_agents/sim/material/PhysicalConstants.gd"

[ -f "$CONST" ] || { echo "check_hydrosphere_mass: MISSING ${CONST#"$ROOT"/}" >&2; exit 2; }
M_H2O="$(sed -n 's/^const MOLAR_MASS_WATER_KG_MOL: float = \([0-9.eE+-]*\).*/\1/p' "$CONST" | head -1)"
if [ -z "$M_H2O" ]; then
	echo "check_hydrosphere_mass: PhysicalConstants.gd declares no MOLAR_MASS_WATER_KG_MOL, so moles" >&2
	echo "                        cannot be weighed." >&2
	exit 2
fi

out="$("$ROOT/scripts/sim_run.sh" --body --rung 1 --frames "$FRAMES" \
	--report "h2o_total,body_seed_hydrosphere_kg" 2>&1)"
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
echo "The seeded hydrosphere departs from the body's by more than docs/HYDROSPHERE_SEED_REL. The sea" >&2
echo "water is laid where LAWaterFill left it on the seeded crust, and the field" >&2
echo "reads that shape by chords over the terrain lattice; a departure past the ratchet is a lattice or" >&2
echo "chord defect, never a budget to scale the water to." >&2
exit 1
