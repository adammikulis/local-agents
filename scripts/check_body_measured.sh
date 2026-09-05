#!/usr/bin/env bash
# A BODY IS SEEDED AND EVERYTHING ELSE ABOUT IT IS MEASURED. Its mass is the matter that was seeded, its
# radius is where that matter ends, its gravity follows from both, and its day is the seeded angular
# momentum over the inertia the matter has. This asserts the measurement agrees with the seed, which is
# the check that would have caught a planet ten times heavier than the one it was asked for.
# THE ARM IS THE BODY: a box on the surface is not the body, so on a slice arm this is NOT EXAMINED.
# EXIT 0 clean · 1 a body disagrees with its own seed · 2 could not run · 3 the arm was a slice.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
la_body_scoped "$(basename "$0")" || exit $?

# The grid quantises a sphere into cubes, so the matter that lands is not exactly the matter asked for.
# This is the blockiness of the seeded shape and NOTHING ELSE; it tightens as the grid refines, and it is
# wide enough to be honest while still failing an order of magnitude by three powers of ten.
MASS_TOL="${LA_BODY_MASS_TOL:-0.02}"
# Derived-from-derived: the day is arithmetic over the two measurements, so they agree tightly.
DERIVED_TOL="${LA_BODY_DERIVED_TOL:-0.01}"
FRAMES="${LA_BODY_FRAMES:-6}"

KEYS="body_measured,body_mass_kg,body_seed_mass_kg,body_radius_m,body_inertia_kg_m2,body_seed_spin_l,body_day_s"
out="$(la_report "$KEYS" --path "$REPO_ROOT" --body --frames "$FRAMES" 2>&1)"
rc=$?

val() {
	printf '%s\n' "$out" | sed -n "s/^$1  *= *//p" | head -1 \
		| sed -e "s/.*'cur': *//" -e 's/[,}].*//' -e "s/[^0-9eE.+-]//g"
}
flag() { printf '%s\n' "$out" | sed -n "s/^$1  *= *//p" | head -1 | tr -d '[:space:]'; }

measured="$(flag body_measured)"
if [ -z "$measured" ]; then
	echo "ERROR: the run published no body block (sim_run exit $rc), so the body went unmeasured." >&2
	printf '%s\n' "$out" | tail -20 >&2
	exit 2
fi
if [ "$measured" != "True" ] && [ "$measured" != "true" ]; then
	echo "FAIL  body_measured is $measured: the field seeded no matter this body could be measured off." >&2
	exit 1
fi

m="$(val body_mass_kg)"; m_seed="$(val body_seed_mass_kg)"
r="$(val body_radius_m)"
inertia="$(val body_inertia_kg_m2)"; spin_l="$(val body_seed_spin_l)"; day="$(val body_day_s)"
for n in m m_seed r inertia spin_l day; do
	v="$(eval printf '%s' "\$$n")"
	printf '%s' "$v" | grep -Eq '^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$' || {
		echo "ERROR: $n did not arrive as a number; a missing measurement is not a pass." >&2
		printf '%s\n' "$out" | tail -20 >&2
		exit 2
	}
done

echo "BODY_MEASURED={\"mass_rel\":$(awk -v a="$m" -v b="$m_seed" 'BEGIN{printf "%.4f", (b>0)?(a/b-1):-999}')}"

fail=0
awk -v a="$m" -v b="$m_seed" -v t="$MASS_TOL" 'BEGIN{exit !(b>0 && ((a/b-1)<t && (a/b-1)>-t))}' || {
	echo "FAIL  the body holds a mass its seed did not ask for, past $MASS_TOL." >&2
	echo "      Mass is not a number anybody types: it is the matter the seeder spent. A disagreement" >&2
	echo "      this size is the seed creating or losing matter, not the grid's blockiness." >&2
	fail=1
}
# The day is the seeded angular momentum over the measured inertia, and nothing else.
awk -v d="$day" -v i="$inertia" -v l="$spin_l" -v t="$DERIVED_TOL" \
	'BEGIN{e=2*3.14159265358979*i/l; exit !(l>0 && e>0 && ((d/e-1)<t && (d/e-1)>-t))}' || {
	echo "FAIL  the day length is not the seeded angular momentum over the measured inertia." >&2
	fail=1
}
[ "$fail" -eq 0 ] || exit 1
echo "check_body_measured: OK (mass, radius, gravity and day all follow from the seed)"
