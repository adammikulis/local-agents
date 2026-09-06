#!/usr/bin/env bash
# EVERY BUFFER THE FACE BOUNDARY WRITES MUST BE ONE THE DERIVE DECLARES. FieldBoundary3D fills a ghost
# cell with the same decomposition state_derive.glsl carries, so a name it writes that the kernel's
# binding group does not list is a buffer nobody allocated: the attach fails with `no "<name>" buffer`
# and every rig that stands a boundary up dies with it. `h_h2o_vap` was such a name.
# The three redirect tables are the boundary's OWN geometry, not derived state.
# EXIT 0 every name is declared · 1 one is not · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "check_boundary_buffers: python3 absent." >&2; exit 2; }
python3 - "$ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]
bnd = os.path.join(root, "addons/local_agents/sim/material/FieldBoundary3D.gd")
bind = os.path.join(root, "addons/local_agents/sim/material/Bindings.gd")
for f in (bnd, bind):
    if not os.path.exists(f):
        print("check_boundary_buffers: missing %s" % f, file=sys.stderr)
        raise SystemExit(2)

s = open(bnd, errors="replace").read()
writes = set(re.findall(r'out\["(\w+)"\]\s*=', s))
for m in re.findall(r"out\.merge\(\{([^}]*)\}\)", s):
    writes |= set(re.findall(r'"(\w+)"\s*:', m))
writes |= set(re.findall(r'_upload\("(\w+)"', s))
writes |= set(re.findall(r'_gpu\._bufs\["(\w+)"\]', s))
if not writes:
    print("check_boundary_buffers: FieldBoundary3D names no buffer — the scan found nothing.", file=sys.stderr)
    raise SystemExit(2)

b = open(bind, errors="replace").read()
key = '"state_derive.glsl": ['
if key not in b:
    print("check_boundary_buffers: Bindings.gd declares no state_derive.glsl group.", file=sys.stderr)
    raise SystemExit(2)
grp = b[b.index(key):]
declared = set(re.findall(r'"(\w+)"', grp[:grp.index("],")]))

# The redirect tables the boundary builds itself: a face's ghost tail and the relaxation rim.
OWN = {"ghost", "rim_ghost", "rim_w"}
missing = sorted(n for n in writes if n not in declared and n not in OWN)
print('BOUNDARY_BUFFERS={"written":%d,"undeclared":%d}' % (len(writes), len(missing)))
if missing:
    for n in missing:
        print('  "%s" is written into a ghost cell and state_derive.glsl declares no such buffer' % n)
    print("Add it to LABindings.IN_KERNEL and to the pass that allocates it, or stop writing it.",
          file=sys.stderr)
    raise SystemExit(1)
print("check_boundary_buffers: OK")
PY
