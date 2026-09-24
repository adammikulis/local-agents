#!/usr/bin/env bash
# ONE DECLARATION PER FACT ACROSS THE GDSCRIPT/GLSL BOUNDARY, ENFORCED.
# scripts/gen_shared_constants.py writes the GLSL and gdshader copies from the GDScript declaration. Fails
# when a copy is stale, when a kernel or any .gdshader re-declares a generated name, and when a shader uses
# a generated name without including the generated file by its path, or includes it and uses none.
# EXIT CODES. 0 pass · 1 a copy is stale, a name is declared twice or an include is wrong · 2 could not run.
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
PHYS="$ROOT/addons/local_agents/sim/material/kernels3d/physical.glsli"
INC="$ROOT/addons/local_agents/game/render/shaders/generated.gdshaderinc"
KERNELS="$ROOT/addons/local_agents/sim/material/kernels3d"
ADDON="$ROOT/addons/local_agents"

for f in "$GEN" "$GLSLI" "$PHYS" "$INC"; do
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
python3 - "$GLSLI" "$INC" "$KERNELS" "$ADDON" "$PHYS" "$ROOT" <<'PY'
import glob, os, re, sys
glsli, inc, kernels, addon, phys, root = sys.argv[1:7]


def names(path):
    text = open(path, encoding="utf-8").read()
    out = set(re.findall(r"^#define\s+([A-Za-z_]\w*)", text, re.M))
    out |= set(re.findall(r"^const\s+\w+\s+([A-Za-z_]\w*)", text, re.M))
    return out - {"LA_GENERATED_GLSLI", "LA_PHYSICAL_GLSLI"}


def scan(path, owned):
    text = open(path, encoding="utf-8").read()
    have = set(re.findall(r"^#define\s+([A-Za-z_]\w*)", text, re.M))
    have |= set(re.findall(r"^const\s+\w+\s+([A-Za-z_]\w*)(?:\[\d*\])?\s*=", text, re.M))
    return sorted(have & owned)


def gdshaders():
    out = []
    for dp, dirs, files in os.walk(addon):
        dirs[:] = [d for d in dirs if d != "thirdparty"]
        out += [os.path.join(dp, f) for f in files if f.endswith((".gdshader", ".gdshaderinc"))]
    return sorted(p for p in out if not os.path.samefile(p, inc))


def code(path):
    text = open(path, encoding="utf-8").read()
    return re.sub(r'"[^"\n]*"|/\*.*?\*/|//[^\n]*',
                  lambda m: m.group(0) if m.group(0).startswith('"') else "", text, flags=re.S)


bad = 0
shaders = gdshaders()
if not shaders:
    print("check_generated_constants: no .gdshader under %s — the gate has no subject." % addon, file=sys.stderr)
    sys.exit(2)
for src, tree in ((glsli, sorted(glob.glob(os.path.join(kernels, "*.glsl")))),
                  (phys, sorted(glob.glob(os.path.join(kernels, "*.gl*")))), (inc, shaders)):
    owned = names(src)
    if not owned:
        print("check_generated_constants: %s declares nothing — refusing to pass on an empty comparison."
              % os.path.basename(src), file=sys.stderr)
        sys.exit(2)
    for path in tree:
        if os.path.samefile(path, src):
            continue
        clash = scan(path, owned)
        if clash:
            print("SECOND DECLARATION %s: %s" % (os.path.relpath(path, root), ", ".join(clash)), file=sys.stderr)
            bad = 1

# A shader that uses a generated name includes the generated file by its path; one that includes it uses one.
owned = names(inc)
want = "res://" + os.path.relpath(inc, root).replace(os.sep, "/")
uses_re = re.compile(r"\b(%s)\b" % "|".join(sorted(owned)))
for path in shaders:
    body = code(path)
    included = re.findall(r'^[ \t]*#include[ \t]+"([^"]*generated\.gdshaderinc)"', body, re.M)
    uses = bool(uses_re.search(re.sub(r"^[ \t]*#include[^\n]*", "", body, flags=re.M)))
    rel = os.path.relpath(path, root)
    if uses and want not in included:
        print("MISSING INCLUDE %s uses a generated name without #include \"%s\"" % (rel, want), file=sys.stderr)
        bad = 1
    if included and not uses:
        print("DEAD INCLUDE %s includes generated.gdshaderinc and uses no name from it" % rel, file=sys.stderr)
        bad = 1
    for got in included:
        if got != want:
            print("STALE INCLUDE %s names %s; the include is %s" % (rel, got, want), file=sys.stderr)
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
for f in "$KERNELS/reactions_sphere3d.glsl" "$KERNELS/flux.glsl"; do
  [ -f "$f" ] || { echo "check_generated_constants: MISSING ${f#"$ROOT"/} — drop it from this list." >&2; exit 2; }
  grep -q '#include "generated.glsli"' "$f" || {
    echo "MISSING INCLUDE ${f#"$ROOT"/} does not include generated.glsli" >&2; fail=1; }
done
for f in "$KERNELS/state_derive.glsl" "$KERNELS/reactions_sphere3d.glsl" "$KERNELS/enthalpy_selftest.glsl"; do
  [ -f "$f" ] || { echo "check_generated_constants: MISSING ${f#"$ROOT"/} — drop it from this list." >&2; exit 2; }
  grep -q '#include "physical.glsli"' "$f" || {
    echo "MISSING INCLUDE ${f#"$ROOT"/} does not include physical.glsli" >&2; fail=1; }
done

if [ "$fail" -ne 0 ]; then
  echo "check_generated_constants: FAILED." >&2
  exit 1
fi
echo "Generated-constants gate passed."
