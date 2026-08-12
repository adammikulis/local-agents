#!/usr/bin/env bash
# TWO BUFFERS ON ONE BINDING NUMBER COMPILE, AND THE LATER WRITE WINS.
#
# state_derive.glsl once declared bindings 31/32/33 twice: one lane's gas-moles / condensed-density /
# conductivity aliased another lane's phase fractions, and the pass bound 33 twice. Both sides compiled,
# the merge was clean, and pressure.glsl spent every step computing the planet's lithostatic column from
# the LIQUID WATER FRACTION as if it were kg/m^3. A merge conflict would have been the good outcome.
#
# 1. no .glsl declares one (set, binding) twice
# 2. no pass builds a uniform set with the same index twice
#
# EXIT 0 clean · 1 a collision · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "check_binding_collisions: python3 absent." >&2; exit 2; }

python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
KERNELS = os.path.join(root, "addons/local_agents/sim/material/kernels3d")
PASSES = os.path.join(root, "addons/local_agents/sim/material/sphere_passes")
for p in (KERNELS, PASSES):
    if not os.path.isdir(p):
        print("check_binding_collisions: MISSING %s" % p, file=sys.stderr); sys.exit(2)

bad = []
scanned = 0

for fn in sorted(os.listdir(KERNELS)):
    if not fn.endswith((".glsl", ".glsli")):
        continue
    src = open(os.path.join(KERNELS, fn), encoding="utf-8").read()
    seen = {}
    for m in re.finditer(r"layout\s*\(\s*set\s*=\s*(\d+)\s*,\s*binding\s*=\s*(\d+)[^)]*\)\s*"
                         r"(?:restrict\s+)?(?:readonly\s+|writeonly\s+)?(?:buffer|uniform)\s+(\w+)", src):
        scanned += 1
        key = (int(m.group(1)), int(m.group(2)))
        name = m.group(3)
        if key in seen:
            bad.append("%s declares set %d binding %d twice: %s and %s"
                       % (fn, key[0], key[1], seen[key], name))
        else:
            seen[key] = name

# A pass builds its set as a list of [index, rid] pairs, one _uset call per parity.
for fn in sorted(os.listdir(PASSES)):
    if not fn.endswith(".gd"):
        continue
    src = open(os.path.join(PASSES, fn), encoding="utf-8").read()
    for call in re.finditer(r"_uset\s*\(\s*[^,]+,\s*\[(.*?)\]\s*\)", src, re.S):
        body = call.group(1)
        idx = [int(x) for x in re.findall(r"\[\s*(\d+)\s*,", body)]
        scanned += len(idx)
        dupes = sorted({i for i in idx if idx.count(i) > 1})
        for d in dupes:
            bad.append("%s builds a uniform set binding %d twice" % (fn, d))

if scanned == 0:
    print("check_binding_collisions: found no bindings — the gate has no subject.", file=sys.stderr)
    sys.exit(2)

if bad:
    print("check_binding_collisions: FAILED", file=sys.stderr)
    for b in bad:
        print("  " + b, file=sys.stderr)
    print("\nTwo buffers on one binding number compile. The later write wins and the kernel reads the\n"
          "wrong quantity, silently, for as long as nobody notices.", file=sys.stderr)
    sys.exit(1)

print("check_binding_collisions: OK (%d bindings, no collisions)" % scanned)
PY
