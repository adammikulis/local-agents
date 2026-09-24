#!/usr/bin/env bash
# StateDerivePass.gd packs the props rows state_derive.glsl reads, and LAMixtureEnthalpy::thermal_row the
# ladder inside them: every PROP_*, PH_* and TH_* offset, and the melting line's step count, is one number
# declared on each side and equal.
# EXIT 0 the layouts agree * 1 they differ * 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3
GD="${LA_PROPS_GD:-$ROOT/addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd}"
GLSL="${LA_PROPS_GLSL:-$ROOT/addons/local_agents/sim/material/kernels3d/state_derive.glsl}"
HPP="${LA_PROPS_HPP:-$ROOT/addons/local_agents/gdextensions/localagents/include/LAMixtureEnthalpy.hpp}"
LINE_HPP="$ROOT/addons/local_agents/gdextensions/localagents/include/LAMeltingLine.hpp"
LINE_GLSL="$ROOT/addons/local_agents/sim/material/kernels3d/enthalpy.glsli"
for f in "$GD" "$GLSL" "$HPP" "$LINE_HPP" "$LINE_GLSL"; do
	[ -f "$f" ] || { echo "check_derive_props_layout: MISSING $f" >&2; exit 2; }
done
python3 - "$GD" "$GLSL" "$HPP" "$LINE_HPP" "$LINE_GLSL" <<'PY'
import re, sys
glsl = open(sys.argv[2]).read()
gd = dict(re.findall(r'^const ((?:PROP|PH)_[A-Z0-9_]+): int = (\d+)', open(sys.argv[1]).read(), re.M))
gl = dict(re.findall(r'^const int ((?:PROP|PH)_[A-Z0-9_]+) = (\d+);', glsl, re.M))
cpp_th = dict(re.findall(r'static constexpr int (TH_[A-Z0-9_]+) = (\d+);', open(sys.argv[3]).read()))
gl_th = dict(re.findall(r'^const int (TH_[A-Z0-9_]+) = (\d+);', glsl, re.M))
words = re.search(r'static const int THERMAL_ROW_WORDS = (\d+);', open(sys.argv[3]).read())
steps_cpp = re.search(r'constexpr int STEPS = (\d+);', open(sys.argv[4]).read())
steps_gl = re.search(r'const int LA_FUSION_STEPS = (\d+);', open(sys.argv[5]).read())
if not gd or not gl or not cpp_th or not gl_th or not words or not steps_cpp or not steps_gl:
    print("check_derive_props_layout: no offsets read on one side, so nothing was compared.", file=sys.stderr)
    sys.exit(2)
bad = []
for name in sorted(set(gd) | set(gl)):
    if gd.get(name) != gl.get(name):
        bad.append("  %-18s StateDerivePass.gd %s  state_derive.glsl %s" % (name, gd.get(name), gl.get(name)))
for name in sorted(set(cpp_th) | set(gl_th)):
    if cpp_th.get(name) != gl_th.get(name):
        bad.append("  %-18s LAMixtureEnthalpy.hpp %s  state_derive.glsl %s" % (name, cpp_th.get(name), gl_th.get(name)))
if int(gl.get("PROP_STRIDE", -1)) != int(gl.get("PROP_LADDER", -1)) + int(words.group(1)):
    bad.append("  PROP_STRIDE is not PROP_LADDER + THERMAL_ROW_WORDS")
if steps_cpp.group(1) != steps_gl.group(1):
    bad.append("  melting-line steps: LAMeltingLine.hpp %s  enthalpy.glsli %s" % (steps_cpp.group(1), steps_gl.group(1)))
if bad:
    print("check_derive_props_layout: the packer and the kernel disagree on the props layout:", file=sys.stderr)
    print("\n".join(bad), file=sys.stderr)
    sys.exit(1)
print("check_derive_props_layout: OK (%d offsets, the same on both sides)" % (len(gd) + len(cpp_th)))
PY
