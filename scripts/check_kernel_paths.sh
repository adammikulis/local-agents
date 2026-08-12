#!/usr/bin/env bash
# Every res:// kernel path a pass names must exist.
#
# A missing kernel makes SpherePass._kernel return RID(), _dispatchable() false, and the WHOLE PASS a
# silent no-op while the run still prints a full report. AtmospherePass lost precipitation this way.
#
# EXIT 0 clean · 1 a path names nothing · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${LA_KP_SRC:-$ROOT/addons/local_agents}"
[ -d "$SRC" ] || { echo "check_kernel_paths: MISSING $SRC" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "check_kernel_paths: python3 absent." >&2; exit 2; }

python3 - "$ROOT" "$SRC" <<'PY'
import os, re, sys
root, src = sys.argv[1], sys.argv[2]
pat = re.compile(r'"(res://[^"]+\.(?:glsl|glsli|gdshader|gdshaderinc|tscn|tres|gd))"')
missing, checked = [], 0
for dp, _, names in os.walk(src):
    if "/thirdparty/" in dp:
        continue
    for n in names:
        if not n.endswith((".gd", ".glsl", ".glsli")):
            continue
        p = os.path.join(dp, n)
        for m in pat.finditer(open(p, errors="replace").read()):
            checked += 1
            target = os.path.join(root, m.group(1)[len("res://"):])
            if not os.path.exists(target):
                missing.append((os.path.relpath(p, root), m.group(1)))
if not checked:
    print("check_kernel_paths: no res:// paths found — the gate has no subject.", file=sys.stderr)
    sys.exit(2)
if missing:
    print("check_kernel_paths: FAILED — a pass names a file that does not exist:", file=sys.stderr)
    for where, what in sorted(set(missing)):
        print("  %-58s -> %s" % (where, what), file=sys.stderr)
    print("\nA missing kernel loads as null and its whole pass silently does not run.", file=sys.stderr)
    sys.exit(1)
print("check_kernel_paths: OK (%d paths)" % checked)
PY
