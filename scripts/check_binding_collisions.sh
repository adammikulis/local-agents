#!/usr/bin/env bash
# TWO BUFFERS ON ONE BINDING NUMBER COMPILE, AND THE LATER WRITE WINS.
#
# state_derive.glsl once declared bindings 31/32/33 twice: one lane's gas-moles / condensed-density /
# conductivity aliased another lane's phase fractions, and the pass bound 33 twice. Both sides compiled,
# the merge was clean, and pressure.glsl spent every step computing the planet's lithostatic column from
# the LIQUID WATER FRACTION as if it were kg/m^3. A merge conflict would have been the good outcome.
#
# 1. no .glsl declares one (set, binding) twice, COUNTING WHAT ITS #includes DECLARE
# 2. no .glsli declares one (set, binding) twice
# 3. no pass builds a uniform set with the same index twice
# 4. no pass binds an index its kernel never declares
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

# Any order and number of memory qualifiers, and set= / binding= in either order inside the layout.
DECL = re.compile(
    r"layout\s*\(([^)]*)\)\s*"
    r"(?:(?:restrict|readonly|writeonly|coherent|volatile|nonprivate)\s+)*"
    r"(?:buffer|uniform)\s+(\w+)")
SET_RE = re.compile(r"\bset\s*=\s*(\d+)")
BINDING_RE = re.compile(r"\bbinding\s*=\s*(\d+)")
INCLUDE = re.compile(r'^\s*#\s*include\s+"([^"]+)"', re.M)

bad = []
scanned = 0
missing = []


def read(path):
    return open(path, encoding="utf-8").read()


def decls(src, fn):
    # (set, binding) -> name, in declaration order. Bindings only; a layout without one is not a descriptor.
    out = []
    for m in DECL.finditer(src):
        layout, name = m.group(1), m.group(2)
        b = BINDING_RE.search(layout)
        if b is None:
            continue
        s = SET_RE.search(layout)
        out.append(((int(s.group(1)) if s else 0, int(b.group(1))), name, fn))
    return out


def includes_of(fn, seen):
    # Transitive #include closure, by filename, within kernels3d.
    src = read(os.path.join(KERNELS, fn))
    for inc in INCLUDE.findall(src):
        base = os.path.basename(inc)
        if base in seen:
            continue
        if not os.path.isfile(os.path.join(KERNELS, base)):
            missing.append("%s includes %s, which is not in kernels3d" % (fn, base))
            continue
        seen.add(base)
        includes_of(base, seen)
    return seen


def unit_decls(fn):
    # Everything the compiler sees for this translation unit: the file plus its include closure.
    units = [fn] + sorted(includes_of(fn, set()))
    out = []
    for u in units:
        out += decls(read(os.path.join(KERNELS, u)), u)
    return out


def check_collisions(label, entries):
    global scanned
    seen = {}
    for key, name, origin in entries:
        scanned += 1
        if key in seen:
            prev_name, prev_origin = seen[key]
            bad.append("%s declares set %d binding %d twice: %s (%s) and %s (%s)"
                       % (label, key[0], key[1], prev_name, prev_origin, name, origin))
        else:
            seen[key] = (name, origin)
    return seen


kernel_bindings = {}   # kernel filename -> set of binding indices in set 0
for fn in sorted(os.listdir(KERNELS)):
    if fn.endswith(".glsl"):
        entries = unit_decls(fn)
        seen = check_collisions(fn, entries)
        kernel_bindings[fn] = {b for (s, b) in seen if s == 0}
    elif fn.endswith(".glsli"):
        check_collisions(fn, decls(read(os.path.join(KERNELS, fn)), fn))

if missing:
    print("check_binding_collisions: cannot resolve an #include — the gate would under-count.", file=sys.stderr)
    for m in missing:
        print("  " + m, file=sys.stderr)
    sys.exit(2)

# A pass builds its set as a list of [index, rid] pairs, one _uset call per parity.
USET = re.compile(r"_uset\s*\(\s*[^,]+,\s*\[(.*?)\]\s*\)", re.S)
KERNEL_LIT = re.compile(r'"res://addons/local_agents/sim/material/kernels3d/([\w.]+\.glsl)"')

for fn in sorted(os.listdir(PASSES)):
    if not fn.endswith(".gd"):
        continue
    src = read(os.path.join(PASSES, fn))
    calls = list(USET.finditer(src))
    if not calls:
        continue
    kernels = sorted(set(KERNEL_LIT.findall(src)))
    if len(kernels) != 1:
        print("check_binding_collisions: %s builds a uniform set but names %d kernels — the gate cannot "
              "tell which kernel its bindings must exist in." % (fn, len(kernels)), file=sys.stderr)
        sys.exit(2)
    declared = kernel_bindings.get(kernels[0])
    if declared is None:
        print("check_binding_collisions: %s names %s, which is not in kernels3d."
              % (fn, kernels[0]), file=sys.stderr)
        sys.exit(2)
    for call in calls:
        idx = [int(x) for x in re.findall(r"\[\s*(\d+)\s*,", call.group(1))]
        scanned += len(idx)
        for d in sorted({i for i in idx if idx.count(i) > 1}):
            bad.append("%s builds a uniform set binding %d twice" % (fn, d))
        for u in sorted({i for i in idx if i not in declared}):
            bad.append("%s binds %d, which %s never declares" % (fn, u, kernels[0]))

if scanned == 0:
    print("check_binding_collisions: found no bindings — the gate has no subject.", file=sys.stderr)
    sys.exit(2)

if bad:
    print("check_binding_collisions: FAILED", file=sys.stderr)
    for b in sorted(set(bad)):
        print("  " + b, file=sys.stderr)
    print("\nTwo buffers on one binding number compile. The later write wins and the kernel reads the\n"
          "wrong quantity, silently, for as long as nobody notices. A bound index the kernel never\n"
          "declares is a buffer nothing reads.", file=sys.stderr)
    sys.exit(1)

print("check_binding_collisions: OK (%d bindings, no collisions)" % scanned)
PY
