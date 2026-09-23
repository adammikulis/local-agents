#!/usr/bin/env bash
# StateDerivePass.gd packs the props rows state_derive.glsl reads: every PROP_* and PH_* offset is one
# number, declared on both sides and equal.
# EXIT 0 the layouts agree * 1 they differ * 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3
GD="${LA_PROPS_GD:-$ROOT/addons/local_agents/sim/material/sphere_passes/StateDerivePass.gd}"
GLSL="${LA_PROPS_GLSL:-$ROOT/addons/local_agents/sim/material/kernels3d/state_derive.glsl}"
for f in "$GD" "$GLSL"; do
	[ -f "$f" ] || { echo "check_derive_props_layout: MISSING $f" >&2; exit 2; }
done
python3 - "$GD" "$GLSL" <<'PY'
import re, sys
gd = dict(re.findall(r'^const ((?:PROP|PH)_[A-Z0-9_]+): int = (\d+)', open(sys.argv[1]).read(), re.M))
gl = dict(re.findall(r'^const int ((?:PROP|PH)_[A-Z0-9_]+) = (\d+);', open(sys.argv[2]).read(), re.M))
if not gd or not gl:
    print("check_derive_props_layout: no offsets read on one side, so nothing was compared.", file=sys.stderr)
    sys.exit(2)
bad = []
for name in sorted(set(gd) | set(gl)):
    if gd.get(name) != gl.get(name):
        bad.append("  %-18s StateDerivePass.gd %s  state_derive.glsl %s" % (name, gd.get(name), gl.get(name)))
if bad:
    print("check_derive_props_layout: the packer and the kernel disagree on the props layout:", file=sys.stderr)
    print("\n".join(bad), file=sys.stderr)
    sys.exit(1)
print("check_derive_props_layout: OK (%d offsets, the same on both sides)" % len(gd))
PY
