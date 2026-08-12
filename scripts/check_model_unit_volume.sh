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

K="$ROOT/addons/local_agents/sim/material/kernels3d"
python3 - "$K" <<'GLSLCHECK'
import os, re, sys
root = sys.argv[1]

# GLSL is checked per LINE. rc_of/RC_*/RHO_* answer per CUBIC METRE while shell_dr/lat_size/cell_volume
# answer in MODEL units, so the two meeting in one expression is the defect. A length over a length cancels
# and carries no per-metre constant, so it never matches.
PER_M = re.compile(r"\brc_of\b|\bRC_[A-Z0-9_]+\b|\bRHO_[A-Z0-9_]+\b"
                   r"|\b[A-Z][A-Z0-9_]*_KG_M3\b|\b[A-Z][A-Z0-9_]*_M2\b|\b[A-Z][A-Z0-9_]*_J_M3K\b")
MODEL_LEN = re.compile(r"\bshell_dr\s*\(|\bshell_d_out\s*\(|\bshell_d_in\s*\(|\bshell_run\s*\("
                       r"|\bcell_volume\s*\(|\bcell_vol\[|\blat_size\b|\bcell_size\b|\bdr_ref\b")
bad, files = [], 0
for n in sorted(os.listdir(root)):
    if not (n.endswith(".glsl") or n.endswith(".glsli")):
        continue
    files += 1
    for i, ln in enumerate(open(os.path.join(root, n), errors="replace").read().splitlines()):
        code = re.sub(r"//.*$", "", ln)
        if "METRES_PER_MODEL_UNIT" in code:
            continue
        m = PER_M.search(code)
        if m and MODEL_LEN.search(code):
            bad.append((n, i + 1, m.group(0)))
if files == 0:
    print("check_model_unit_volume: scanned 0 kernels - the tree moved.", file=sys.stderr)
    sys.exit(2)
if bad:
    print("check_model_unit_volume: FAILED - a per-m^3 quantity meets a MODEL-unit length in a kernel",
          file=sys.stderr)
    for n, line, sym in bad:
        print("  kernels3d/%s:%d  %s" % (n, line, sym), file=sys.stderr)
    print("  shell_dr/lat_size/cell_volume answer in model units. Convert with METRES_PER_MODEL_UNIT.",
          file=sys.stderr)
    sys.exit(1)
print("check_model_unit_volume: OK (%d kernels)" % files)
GLSLCHECK
glsl_rc=$?

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
gd_rc=$?

if [ "$glsl_rc" -ne 0 ]; then exit "$glsl_rc"; fi
exit "$gd_rc"
