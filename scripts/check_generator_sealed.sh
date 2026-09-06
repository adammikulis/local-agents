#!/usr/bin/env bash
# THE SEED'S SHAPE IS READ ONCE AND NEVER WRITTEN, so the field is the one thing that changes after the
# seal. What still reads it: docs/APPROXIMATIONS.md's godot_voxel_mesher_over_generator.
# MUTATION: a carve_sphere holding a VoxelTool -> red; a second sample_solidity caller -> red.
# EXIT 0 nothing writes the shape * 1 something does * 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool rg

SIM="$ROOT/addons/local_agents"
[ -d "$SIM" ] || { echo "check_generator_sealed: no $SIM to scan." >&2; exit 2; }

fail=0

# A VoxelTool is the only handle that edits a streamed voxel volume; holding one is the write.
EDITS="$(rg -N -n --glob '!*.md' -e 'get_voxel_tool|VoxelTool\.' "$SIM" || true)"
if [ -n "$EDITS" ]; then
	echo "check_generator_sealed: the terrain's voxel volume is edited here:" >&2
	printf '%s\n' "$EDITS" >&2
	fail=1
fi

# A method by these names is the shape being changed under the field.
VERBS="$(rg -N -n --glob '!*.md' --glob '!scripts/check_generator_sealed.sh' \
	-e 'func (carve_sphere|fill_sphere|_edit_sphere|resample_terrain)' "$SIM" || true)"
if [ -n "$VERBS" ]; then
	echo "check_generator_sealed: these write the seed's shape after it is laid:" >&2
	printf '%s\n' "$VERBS" >&2
	fail=1
fi

# The field samples the shape once. More than one caller is a second sampling, and a caller outside the
# seeding tick is one after the seal.
CALLS="$(rg -N -n --glob '!*.md' -e '\.sample_solidity\(\)' "$SIM" || true)"
N="$(printf '%s' "$CALLS" | grep -c . || true)"
if [ "$N" -ne 1 ]; then
	echo "check_generator_sealed: sample_solidity has $N callers; the shape is sampled once, while seeding." >&2
	printf '%s\n' "$CALLS" >&2
	fail=1
elif ! printf '%s' "$CALLS" | rg -q 'MaterialFieldSphereStep3D\.gd'; then
	echo "check_generator_sealed: sample_solidity is called from outside the seeding tick:" >&2
	printf '%s\n' "$CALLS" >&2
	fail=1
fi

echo "GENERATOR_SEALED={\"voxel_tool_sites\":$(printf '%s' "$EDITS" | grep -c . || true),\"write_verbs\":$(printf '%s' "$VERBS" | grep -c . || true),\"sample_callers\":$N}"
[ "$fail" -eq 0 ] || exit 1
echo "check_generator_sealed: OK (nothing edits the seed's shape; the field samples it once)"
exit 0
