#!/usr/bin/env bash
# A kernel never differences two full potentials: float32 cannot hold phi at a body's radius to better
# than metres of height. A potential DROP across a face is the pair's gravity integrated (la_dphi).
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg
K="$ROOT/addons/local_agents/sim/material/kernels3d"
bad="$(rg -n 'la_phi\([^)]*\)[^;]*la_phi\(|grav_ref\[[^]]*\][^;]*grav_ref\[' "$K" --glob '!gravity_poisson.glsl' || true)"
if [ -n "$bad" ]; then
	echo "check_potential_differences: FAIL — a kernel differences two full potentials:" >&2
	echo "$bad" >&2
	exit 1
fi
n="$(rg -c 'la_phi\(' "$K/closures.glsli" | tail -1)"
echo "POTENTIAL_DIFFERENCES={\"la_phi_sites\":${n:-0},\"failures\":0}"
echo "check_potential_differences: OK (no kernel differences two full potentials)"
