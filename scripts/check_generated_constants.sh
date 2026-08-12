#!/usr/bin/env bash
# ONE DECLARATION PER FACT ACROSS THE GDSCRIPT/GLSL BOUNDARY, ENFORCED.
#
# Slot enums, gate bitflags, predicate flags, the regolith depth, the cube-face frames and the ripple
# ring length were each written down twice and held equal by a comment saying "MUST match". A comment
# cannot fail. scripts/gen_shared_constants.py emits the GLSL and gdshader copies from the GDScript
# declaration; this gate fails when the checked-in copy no longer matches its source, when a consumer
# re-declares a generated name, and when a consumer stopped including the generated file.
#
# EXIT CODES. 0 pass · 1 a copy is stale or a name is declared twice · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib_require.sh
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
if declare -f require_tool >/dev/null 2>&1; then
  require_tool python3
elif ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: check_generated_constants requires python3 and it is not installed." >&2
  exit 2
fi

GEN="$ROOT/scripts/gen_shared_constants.py"
GLSLI="$ROOT/addons/local_agents/sim/material/kernels3d/generated.glsli"
INC="$ROOT/addons/local_agents/sim/shaders/generated.gdshaderinc"
KERNELS="$ROOT/addons/local_agents/sim/material/kernels3d"
SHADERS="$ROOT/addons/local_agents/sim/shaders"

for f in "$GEN" "$GLSLI" "$INC"; do
  [ -f "$f" ] || { echo "check_generated_constants: MISSING ${f#"$ROOT"/}" >&2; exit 2; }
done

fail=0

# 1. THE CHECKED-IN COPY IS WHAT THE GENERATOR WOULD WRITE TODAY.
python3 "$GEN" --check
rc=$?
[ "$rc" -eq 2 ] && exit 2
[ "$rc" -ne 0 ] && fail=1

# 2. NO CONSUMER RE-DECLARES A GENERATED NAME. A second declaration is what this gate exists to stop, and
# a local copy shadowing the include is how the two drift apart again.
python3 - "$GLSLI" "$INC" "$KERNELS" "$SHADERS" <<'PY'
import glob, os, re, sys
glsli, inc, kernels, shaders = sys.argv[1:5]


def names(path):
    text = open(path, encoding="utf-8").read()
    out = set(re.findall(r"^#define\s+([A-Za-z_]\w*)", text, re.M))
    out |= set(re.findall(r"^const\s+\w+\s+([A-Za-z_]\w*)", text, re.M))
    return out - {"LA_GENERATED_GLSLI"}


def scan(path, owned):
    text = open(path, encoding="utf-8").read()
    have = set(re.findall(r"^#define\s+([A-Za-z_]\w*)", text, re.M))
    have |= set(re.findall(r"^const\s+\w+\s+([A-Za-z_]\w*)(?:\[\d*\])?\s*=", text, re.M))
    return sorted(have & owned)


bad = 0
# A RENAMED COPY IS STILL A COPY. VoxelWater.gdshader carried the cube-face frames a second time as
# ICE_FACE_*, which a name comparison cannot see. The six-entry vec3 table is the frame and nothing else.
for path in sorted(glob.glob(os.path.join(shaders, "*.gdshader"))):
    if re.search(r"vec3\[6\]\(", open(path, encoding="utf-8").read()):
        print("RENAMED COPY %s declares a vec3[6] table; use FACE_N/FACE_R/FACE_U from the include."
              % os.path.basename(path), file=sys.stderr)
        bad = 1

for src, tree, ext in ((glsli, kernels, "*.glsl"), (inc, shaders, "*.gdshader")):
    owned = names(src)
    if not owned:
        print("check_generated_constants: %s declares nothing — refusing to pass on an empty comparison."
              % os.path.basename(src), file=sys.stderr)
        sys.exit(2)
    for path in sorted(glob.glob(os.path.join(tree, ext))):
        clash = scan(path, owned)
        if clash:
            print("SECOND DECLARATION %s: %s" % (os.path.basename(path), ", ".join(clash)), file=sys.stderr)
            bad = 1
sys.exit(bad)
PY
rc=$?
[ "$rc" -eq 2 ] && exit 2
[ "$rc" -ne 0 ] && fail=1

# 3. A CONSUMER THAT USES A GENERATED NAME PULLS IT IN. Without this the include can be dropped and the
# kernel silently falls back to nothing, which is a compile error the runtime reports as a null SPIR-V.
# The consumer list is named, not derived: a buffer block called CO2 would read as a slot to a "uses a
# generated name" rule. A consumer that is GONE fails the gate — delete its line in the same commit.
for f in "$KERNELS/cell_list_sphere3d.glsl" "$KERNELS/reactions_sphere3d.glsl" "$KERNELS/transport.glsl"; do
  [ -f "$f" ] || { echo "check_generated_constants: MISSING ${f#"$ROOT"/} — drop it from this list." >&2; exit 2; }
  grep -q '#include "generated.glsli"' "$f" || {
    echo "MISSING INCLUDE ${f#"$ROOT"/} does not include generated.glsli" >&2; fail=1; }
done
for f in "$SHADERS/VoxelWater.gdshader" "$SHADERS/VoxelWaterSphere.gdshader" \
         "$SHADERS/VoxelTerrainTriplanar.gdshader" "$SHADERS/WaterParticles.gdshader"; do
  [ -f "$f" ] || { echo "check_generated_constants: MISSING ${f#"$ROOT"/}" >&2; exit 2; }
  grep -q 'generated.gdshaderinc' "$f" || {
    echo "MISSING INCLUDE ${f#"$ROOT"/} does not include generated.gdshaderinc" >&2; fail=1; }
done

if [ "$fail" -ne 0 ]; then
  echo "check_generated_constants: FAILED." >&2
  exit 1
fi
echo "Generated-constants gate passed."
