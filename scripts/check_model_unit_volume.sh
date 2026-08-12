#!/usr/bin/env bash
# A per-m^3 or per-m^2 quantity must never meet a raw cell size: the field's lengths are MODEL units
# (LAPhysical.METRES_PER_MODEL_UNIT metres each), so `J_M3K * cell_size^3` is off by that cubed.
#
# Trips when a function mentions a `*_M3*` / `*_M2*` constant or LAHeatCapacity.cell AND a raw cell size,
# without METRES_PER_MODEL_UNIT or the LAMaterialFieldCellVolume3D accessor. A ratio in which the same
# per-m^3 constant appears on both sides cancels and is allowed.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/addons/local_agents"
[ -d "$SRC" ] || { echo "check_model_unit_volume: MISSING $SRC" >&2; exit 2; }

python3 - "$SRC" <<'PY'
import os, re, sys
root = sys.argv[1]

PER_UNIT = re.compile(r'\b[A-Z][A-Z0-9_]*_(?:KG_)?M3[A-Z0-9_]*\b|\b[A-Z][A-Z0-9_]*_M2[A-Z0-9_]*\b'
                      r'|LAHeatCapacity\.cell\b')
RAW_SIZE = re.compile(r'\b_?cell_size\b|\bfloat\(\s*\w+\._cell_size\s*\)')
EXEMPT = re.compile(r'METRES_PER_MODEL_UNIT|LAMaterialFieldCellVolume3D')
EXEMPT_FILES = {"MaterialFieldCellVolume3D.gd", "PhysicalConstants.gd"}

files, bad = 0, []
for dirpath, _, names in os.walk(root):
    for n in names:
        if not n.endswith(".gd") or n in EXEMPT_FILES:
            continue
        path = os.path.join(dirpath, n)
        files += 1
        body, start, lines = [], 0, open(path, errors="replace").read().splitlines()
        def flush(body, start):
            if not body:
                return
            # Code only. A token named in a comment is prose, not a use, and counting it both hid a real
            # defect and faked the ratio exemption below.
            text = "\n".join(re.sub(r'#.*$', '', ln) for ln in body)
            if EXEMPT.search(text):
                return
            hits = PER_UNIT.findall(text)
            if not hits or not RAW_SIZE.search(text):
                return
            # A ratio cancels the units: one per-m^3 constant on both sides of a division.
            if "/" in text and len(hits) > 1 and len(set(hits)) == 1:
                return
            bad.append((os.path.relpath(path, root), start + 1, hits[0]))
        for i, ln in enumerate(lines):
            if re.match(r'^(static\s+)?func\s', ln):
                flush(body, start)
                body, start = [ln], i
            elif body:
                body.append(ln)
        flush(body, start)

if files == 0:
    print("check_model_unit_volume: scanned 0 files — the tree moved.", file=sys.stderr)
    sys.exit(2)
if bad:
    print("check_model_unit_volume: FAILED — a per-m^3/m^2 quantity meets a MODEL-unit length", file=sys.stderr)
    for path, line, sym in bad:
        print("  %s:%d  %s" % (path, line, sym), file=sys.stderr)
    print("  Cell lengths are model units. Use LAMaterialFieldCellVolume3D.of() (m^3) or convert with",
          file=sys.stderr)
    print("  LAPhysical.METRES_PER_MODEL_UNIT.", file=sys.stderr)
    sys.exit(1)
print("check_model_unit_volume: OK (%d files)" % files)
PY
