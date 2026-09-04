#!/usr/bin/env bash
# RUNG 2 — HYDROSTATIC. A BODY HAS AS MUCH AIR AS IT HAS, and the box does not decide how much: the seeded
# nitrogen, in moles of N off the element book, against the atmosphere the body record declares. Read at
# rung 2, the first rung that stands a vertical for the column to fall off along.
# EXIT 0 the air is the body's own · 1 it is not · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_rung.sh"

# THE AIR STANDS WHERE THE LAW PUTS IT, read at the grid's own resolution: the quadrature's departure
# is a ratchet, docs/ATMOSPHERE_SEED_REL, never a budget the seed scales to.
CEIL="$ROOT/docs/ATMOSPHERE_SEED_REL"
[ -f "$CEIL" ] || { echo "check_atmosphere_mass: MISSING ${CEIL#"$ROOT"/}" >&2; exit 2; }
TOL="$(grep -v '^#' "$CEIL" | tr -d '[:space:]')"
FRAMES="${LA_ATMOS_FRAMES:-6}"
CONST="$ROOT/addons/local_agents/sim/material/PhysicalConstants.gd"

[ -f "$CONST" ] || { echo "check_atmosphere_mass: MISSING ${CONST#"$ROOT"/}" >&2; exit 2; }
M_N2="$(sed -n 's/^const MOLAR_MASS_NITROGEN_KG_MOL: float = \([0-9.eE+-]*\).*/\1/p' "$CONST" | head -1)"
if [ -z "$M_N2" ]; then
	echo "check_atmosphere_mass: PhysicalConstants.gd declares no MOLAR_MASS_NITROGEN_KG_MOL, so moles" >&2
	echo "                        cannot be weighed." >&2
	exit 2
fi

out="$(la_rung_report 2 "$FRAMES" "nitrogen_all,body_seed_atmosphere_n2_kg")"
rc=$?
moles="$(la_rung_value "$out" nitrogen_all)"
declared="$(la_rung_value "$out" body_seed_atmosphere_n2_kg)"
for n in "$moles" "$declared"; do
	printf '%s' "$n" | grep -Eq '^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$' || {
		echo "check_atmosphere_mass: the run published no numeric nitrogen_all or atmosphere declaration" >&2
		echo "                        (sim_run exit $rc), so nothing was weighed." >&2
		printf '%s\n' "$out" | tail -20 >&2
		exit 2
	}
done
if ! awk -v d="$declared" 'BEGIN{exit !(d > 0)}'; then
	echo "check_atmosphere_mass: the body record declares no atmosphere, so the seed has no air" >&2
	echo "                       budget to be held to." >&2
	exit 2
fi

reading="$(awk -v m="$moles" -v mm="$M_N2" -v d="$declared" \
	'BEGIN{k = m * mm; r = (k - d) / d; printf "%.6g %.6g", k, (r < 0 ? -r : r)}')"
KG="${reading% *}"
REL="${reading#* }"
echo "ATMOSPHERE={\"seeded_kg\":$KG,\"declared_kg\":$declared,\"rel\":$REL}"
if awk -v r="$REL" -v t="$TOL" 'BEGIN{exit !(r <= t)}'; then
	echo "check_atmosphere_mass: OK"
	exit 0
fi
echo >&2
echo "The seeded atmosphere departs from the body's by more than docs/ATMOSPHERE_SEED_REL. The law is" >&2
echo "anchored at sea level in the solved potential and integrated over each cell's own room; a" >&2
echo "departure past the ratchet is a datum, quadrature or room defect, never a budget to scale the" >&2
echo "air to." >&2
exit 1
