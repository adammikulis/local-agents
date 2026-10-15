#!/usr/bin/env bash
# A BODY HAS AS MUCH AIR AS IT HAS, and no box may put more there: the seeded nitrogen, in moles of N off
# the element book, against the atmosphere the body record declares. THE ARM IS THE WHOLE PLANET: a box's
# footprint on the sphere is not a rectangle, so a slab cannot weigh its own share of the column.
# ONE-SIDED: air the seed invents reads as a body carrying more nitrogen than it was given.
# EXIT 0 the air is the body's own · 1 the seed put air the body does not have · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_rung.sh"
. "$ROOT/scripts/lib_capture.sh"

# THE AIR STANDS WHERE THE LAW PUTS IT, read at the grid's own resolution: the quadrature's departure
# is a ratchet, docs/ATMOSPHERE_SEED_REL, never a budget the seed scales to.
CEIL="$ROOT/docs/ATMOSPHERE_SEED_REL"
[ -f "$CEIL" ] || { echo "check_atmosphere_mass: MISSING ${CEIL#"$ROOT"/}" >&2; exit 2; }
TOL="$(grep -v '^#' "$CEIL" | tr -d '[:space:]')"
FRAMES="${LA_ATMOS_FRAMES:-2}"
CONST="$ROOT/addons/local_agents/sim/material/PhysicalConstants.gd"

[ -f "$CONST" ] || { echo "check_atmosphere_mass: MISSING ${CONST#"$ROOT"/}" >&2; exit 2; }
M_N2="$(sed -n 's/^const MOLAR_MASS_NITROGEN_KG_MOL: float = \([0-9.eE+-]*\).*/\1/p' "$CONST" | head -1)"
if [ -z "$M_N2" ]; then
	echo "check_atmosphere_mass: PhysicalConstants.gd declares no MOLAR_MASS_NITROGEN_KG_MOL, so moles" >&2
	echo "                        cannot be weighed." >&2
	exit 2
fi

# Read at rung 2, the first rung that stands a vertical for the column to fall off along. Above the rung
# that opens escape the total is no longer the seed's, so a capture from another world is not read.
RUNG=2
CAP_RUNG="$(la_cap_rung 2>/dev/null || echo "$RUNG")"
if [ "$CAP_RUNG" != "$RUNG" ]; then
	echo "LINT_NOT_EXAMINED: check_atmosphere_mass.sh weighs the seed at rung $RUNG; the capture is rung $CAP_RUNG"
	exit 3
fi
# The whole body, off the shared arm's own body run: the lint takes one on every landing to record the
# slice's exterior, and this gate weighs its air rather than taking a second.
out="$(la_body_report nitrogen_all,body_seed_atmosphere_n2_kg --path "$ROOT" --rung "$RUNG" --frames "$FRAMES")"
rc=$?
[ "$rc" -ne 2 ] || { printf '%s\n' "$out" >&2; exit 2; }
la_rung_require "$out" nitrogen_all body_seed_atmosphere_n2_kg || {
	r=$?
	echo "check_atmosphere_mass: the air was not weighed to a number (sim_run exit $rc)." >&2
	exit "$r"
}
moles="$(la_rung_value "$out" nitrogen_all)"
declared="$(la_rung_value "$out" body_seed_atmosphere_n2_kg)"
if ! awk -v d="$declared" 'BEGIN{exit !(d > 0)}'; then
	echo "check_atmosphere_mass: the body record declares no atmosphere, so the seed has no air to be" >&2
	echo "                       held to." >&2
	exit 2
fi

reading="$(awk -v m="$moles" -v mm="$M_N2" -v d="$declared" \
	'BEGIN{k = m * mm; r = (k - d) / d; printf "%.6g %.6g %.6g", k, r, (r > 0 ? r : 0)}')"
KG="${reading%% *}"
REST="${reading#* }"
REL="${REST%% *}"
OVER="${REST#* }"
echo "ATMOSPHERE={\"seeded_kg\":$KG,\"declared_kg\":$declared,\"rel\":$REL,\"over\":$OVER}"
if awk -v r="$OVER" -v t="$TOL" 'BEGIN{exit !(r <= t)}'; then
	echo "check_atmosphere_mass: OK"
	exit 0
fi
echo >&2
echo "The seeded atmosphere is heavier than the body's own by more than docs/ATMOSPHERE_SEED_REL. The" >&2
echo "law is anchored at sea level in the solved potential and integrated over each cell's own room; a" >&2
echo "departure past the ratchet is a datum, quadrature or room defect, never a budget to scale the" >&2
echo "air to." >&2
exit 1
