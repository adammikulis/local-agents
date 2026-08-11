#!/usr/bin/env bash
# Phase-from-energy has one definition per side of the GPU boundary: kernels3d/enthalpy.glsli and
# LASubstances.enthalpy_to_state. This holds the GLSL constants equal to LAPhysical.
#
# Every value in the GLSL carries a trailing `// CONST_NAME` naming its authority; this compares them.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
G="$ROOT/addons/local_agents/sim/material/kernels3d/enthalpy.glsli"
P="$ROOT/addons/local_agents/sim/material/PhysicalConstants.gd"
S="$ROOT/addons/local_agents/sim/material/Substances.gd"
[ -f "$G" ] || { echo "check_enthalpy_ssot: MISSING $G" >&2; exit 2; }
[ -f "$P" ] || { echo "check_enthalpy_ssot: MISSING $P" >&2; exit 2; }
[ -f "$S" ] || { echo "check_enthalpy_ssot: MISSING $S" >&2; exit 2; }

python3 - "$G" "$P" "$S" <<'PY'
import re, sys
glsl, gd = open(sys.argv[1]).read(), open(sys.argv[2]).read()
sub = open(sys.argv[3]).read()

auth = {}
for m in re.finditer(r'^const\s+([A-Z0-9_]+)\s*:\s*float\s*=\s*([-+0-9.eE]+)', gd, re.M):
    auth[m.group(1)] = float(m.group(2))

pairs = re.findall(r'([-+0-9.eE]+)\s*[;,]?\s*//\s*(?:LAPhysical\.)?([A-Z0-9_]+)\s*$', glsl, re.M)
if not pairs:
    print("check_enthalpy_ssot: no `value // CONST_NAME` pairs found — the GLSL lost its bindings.",
          file=sys.stderr)
    sys.exit(1)

bad = []
for val, name in pairs:
    if name not in auth:
        bad.append((name, val, "NOT IN LAPhysical")); continue
    if abs(float(val) - auth[name]) > abs(auth[name]) * 1e-9:
        bad.append((name, val, repr(auth[name])))
if bad:
    print("check_enthalpy_ssot: FAILED — enthalpy.glsli diverged from LAPhysical:", file=sys.stderr)
    for name, got, want in bad:
        print("  %-36s glsl=%-14s authority=%s" % (name, got, want), file=sys.stderr)
    sys.exit(1)
# THE FORMULA, NOT JUST THE VALUES. Every copy of rc_of read the right constants and put them in four
# incompatible expressions, which no value gate could see. The plateaus must appear in the same order on
# both sides: solid ramp, fusion plateau, liquid ramp, vaporisation plateau, gas ramp.
STEPS = ["h_melt_start", "h_melt_end", "h_boil_start", "h_boil_end", "h_gas_end", "h_diss_end", "h_atom_end", "h_ion_end"]
def order(txt):
    seen = []
    for line in txt.split("\n"):
        if line.strip().startswith(("//", "#")):
            continue
        for k in STEPS:
            if k in line and k not in seen:
                seen.append(k)
    return seen
og, od = order(glsl), order(sub)
if og != STEPS or od != STEPS:
    print("check_enthalpy_ssot: FAILED — the phase ladder differs between the two definitions.",
          file=sys.stderr)
    print("  glsl: %s" % og, file=sys.stderr)
    print("  gd:   %s" % od, file=sys.stderr)
    print("  expected: %s" % STEPS, file=sys.stderr)
    sys.exit(1)
print("Enthalpy SSOT gate passed (%d constants bound to LAPhysical, phase ladder identical)." % len(pairs))
PY
