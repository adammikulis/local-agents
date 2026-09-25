#!/usr/bin/env bash
# WATER IS ONE SUBSTANCE: no sea shell, no sea radius, no sea-level datum. Where water stands is the field's.
# 1. No code names a sea radius, a sea level or a sea shell. 2. The settled free surface's radius is read
# only by LAHydrosphereFill, the seed that lays the water under it and the karst base level.
# Mutation: a sea_radius() on the flat terrain, or a free_surface_r() read in the regolith walk.
# EXIT 0 no sea datum · 1 one is read · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg

SELF="scripts/$(basename "$0")"
SCOPE=(addons/local_agents scripts)
# Source only, as gates.toml carries this gate's own mutations; ripgrep's last matching glob wins.
EXCLUDE=(-g '*.gd' -g '*.glsl' -g '*.glsli' -g '*.cpp' -g '*.hpp' -g '*.h' -g '*.sh' -g '*.py' -g '*.gdshader'
	-g '*.gdshaderinc' -g '*.tscn' -g '!**/thirdparty/**' -g '!**/build/**' -g '!**/build_native/**' -g "!$SELF")
cd "$ROOT" || exit 2

scanned="$(rg --files "${EXCLUDE[@]}" "${SCOPE[@]}" 2>/dev/null | wc -l | tr -d ' ')"
require_scanned "$scanned" 500 "source files"

fail=0
named="$(rg -n -i "${EXCLUDE[@]}" -e 'sea_?radius|sea_?level|\bsea_r\b|\br_sea\b|sea[ _]shell' "${SCOPE[@]}" 2>/dev/null)"
if [ -n "$named" ]; then
	printf '%s\n' "$named" >&2
	echo "check_no_sea_datum: the lines above read a sea radius, a sea level or a sea shell. Read the field's" >&2
	echo "                    water, or ask LAHydrosphereFill where the settled water stands." >&2
	fail=1
fi

ALLOWED='(gdextensions/localagents/(include|src)/LA(HydrosphereFill\.(hpp|cpp)|FieldHydrosphereSeed\.cpp)|sim/terrain/VoxelTerrainService\.gd)$'
readers="$(rg -l "${EXCLUDE[@]}" -e 'free_surface_r\b' "${SCOPE[@]}" 2>/dev/null | rg -v "$ALLOWED")"
if [ -n "$readers" ]; then
	printf '%s\n' "$readers" >&2
	echo "check_no_sea_datum: the files above read the settled free surface's radius. Only the fill, the seed" >&2
	echo "                    that lays the water under it and the karst base level may: anything else is a" >&2
	echo "                    sea-level datum." >&2
	fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "check_no_sea_datum: OK ($scanned source files, no sea datum read)"
