#!/usr/bin/env bash
# AN OPEN CELL MAY NOT BE DENSER THAN THE DENSEST THING THAT CAN FILL IT. Transport bounds a flow by what
# the DONOR holds and by the receiver's free volume; if either is missing, six neighbours deposit into one
# cell in a step and it ends up holding several fills of matter that has nowhere to be.
#
# EXIT 0 every open cell is within the table's densest substance · 1 one is not · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg

out="$("$ROOT/scripts/sim_run.sh" --path "$ROOT" --frames "${LA_DENSITY_FRAMES:-10}" \
	--report rho_max_open 2>&1)" || true
reading="$(printf '%s\n' "$out" | sed -n 's/^rho_max_open  *= *//p' | head -1 \
	| sed -n "s/.*'max': *\([-+0-9.eE]*\).*/\1/p")"
printf '%s' "$reading" | grep -Eq '^[+-]?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$' \
	|| { echo "check_open_cell_density: the run published no rho_max_open." >&2; exit 2; }

# The densest substance the table declares is the ceiling any single cell could reach if it were solid
# through; an OPEN cell is by definition not, so exceeding it is matter with nowhere to be.
LIMIT="$(rg -N -o -e '"density", *([0-9.eE+]+)' -e '"density": *([0-9.eE+]+)' -r '$1' \
	"$ROOT/addons/local_agents/gdextensions/localagents/src/LASubstances.cpp" 2>/dev/null \
	| sort -g | tail -1)"
[ -n "$LIMIT" ] || { echo "check_open_cell_density: no substance density to compare against." >&2; exit 2; }

awk -v r="$reading" -v l="$LIMIT" 'BEGIN {
	if (r > l) {
		printf "check_open_cell_density: an open cell reached %.6g kg/m^3, past the densest substance (%.6g).\n", r, l > "/dev/stderr"
		printf "                         Matter is being put where there is no room for it.\n" > "/dev/stderr"
		exit 1
	}
	printf "check_open_cell_density: OK (peak open cell %.6g kg/m^3, limit %.6g)\n", r, l
}'
