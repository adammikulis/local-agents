#!/usr/bin/env bash
# DECLARED IS NOT DISPATCHED, AND NAMED IS NOT ALLOCATED.
#
# Six defects of this exact shape were found in one day, every one invisible because the file existed,
# compiled, and passed every gate that mentioned it: a kernel with no pass; a pass not in PASS_SCRIPTS;
# a uniform set binding a buffer nothing created; a transport row naming an absent aux; a channel every
# kernel read and nothing wrote. Each had silently disabled a whole subsystem.
#
# 1. Every .glsl in kernels3d/ is loaded by some pass, and that pass is in PASS_SCRIPTS.
# 2. Every buffer a pass asks `bufs` for exists: a channel row, a derived buffer, or one the driver
#    allocates by hand.
#
#
# EXIT 0 clean · 1 a violation · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v python3 >/dev/null 2>&1 || { echo "check_declared_and_dispatched: python3 absent." >&2; exit 2; }

python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
MAT = os.path.join(root, "addons/local_agents/sim/material")
KERNELS = os.path.join(MAT, "kernels3d")
PASSES = os.path.join(MAT, "sphere_passes")
DRIVER = os.path.join(MAT, "MaterialSphereGPU3D.gd")
CHANNELS = os.path.join(MAT, "Channels.gd")

for p in (KERNELS, PASSES, DRIVER, CHANNELS):
    if not os.path.exists(p):
        print("check_declared_and_dispatched: MISSING %s" % p, file=sys.stderr); sys.exit(2)

def read(p):
    with open(p, encoding="utf-8") as fh:
        return fh.read()

driver = read(DRIVER)
m = re.search(r"PASS_SCRIPTS[^=]*=\s*\[(.*?)\]", driver, re.S)
if not m:
    print("check_declared_and_dispatched: no PASS_SCRIPTS in the driver.", file=sys.stderr); sys.exit(2)
registered = set(re.findall(r"sphere_passes/(\w+)\.gd", m.group(1)))
if not registered:
    print("check_declared_and_dispatched: PASS_SCRIPTS parsed to zero passes.", file=sys.stderr); sys.exit(2)

pass_src = {}
for fn in sorted(os.listdir(PASSES)):
    if fn.endswith(".gd"):
        pass_src[fn[:-3]] = read(os.path.join(PASSES, fn))

# --- 1. a kernel with no dispatching pass -------------------------------------------------------------
loaded = {}
for name, src in pass_src.items():
    for k in re.findall(r"kernels3d/(\w+)\.glsl", src):
        loaded.setdefault(k, set()).add(name)

bad_kernel = []
for fn in sorted(os.listdir(KERNELS)):
    if not fn.endswith(".glsl"):
        continue
    stem = fn[:-5]
    if "selftest" in stem:
        continue                                  # exists to be compiled, never dispatched
    owners = loaded.get(stem, set())
    if not owners:
        bad_kernel.append((fn, "no pass loads it"))
    elif not (owners & registered):
        bad_kernel.append((fn, "loaded only by %s, which is not in PASS_SCRIPTS"
                           % ", ".join(sorted(owners))))

# --- 2. a pass naming a buffer nothing allocates -------------------------------------------------------
chan = read(CHANNELS)
rows = re.search(r"static func rows\(\).*?\n\treturn \{(.*?)\n\t\}", chan, re.S)
derived = re.search(r"static func derived_buffers\(\).*?\n\treturn PackedStringArray\(\[(.*?)\]\)", chan, re.S)
allocated = set(re.findall(r'"(\w+)":', rows.group(1))) if rows else set()
allocated |= set(re.findall(r'"(\w+)"', derived.group(1))) if derived else set()
allocated |= set(re.findall(r'_bufs\["(\w+)"\]\s*=', driver))
# A pass declares buffers of its own and the DRIVER allocates them (_allocate_declared), so those are
# allocated too. Without this the gate sees only the channel table and calls every pass-owned buffer
# missing -- it stayed quiet until now only because CellListPass reaches its own by bufs[key].
for _nm, _src in pass_src.items():
    if _nm not in registered:
        continue
    _body = re.search(r"func _buffers\([^)]*\)[^\n]*\n((?:[ \t].*\n|\n)*)", _src)
    if _body:
        allocated |= set(re.findall(r'"(\w+)"', _body.group(1)))
    _rows = re.search(r"static func rows\(\)[^\n]*\n((?:[ \t].*\n|\n)*)", _src)
    if _rows:
        for _k in ("idx", "args", "flag"):
            allocated |= set(re.findall(r'"%s"\s*:\s*"(\w+)"' % _k, _rows.group(1)))
if not allocated:
    print("check_declared_and_dispatched: no buffers found — the gate has no subject.", file=sys.stderr)
    sys.exit(2)

bad_buf = []
for name in sorted(pass_src):
    if name not in registered:
        continue
    asked = set(re.findall(r'_(?:single|pair|half)\(\s*bufs\s*,\s*"(\w+)"', pass_src[name]))
    for b in sorted(asked - allocated):
        bad_buf.append((name, b))

if bad_kernel or bad_buf:
    print("check_declared_and_dispatched: FAILED", file=sys.stderr)
    for fn, why in bad_kernel:
        print("  kernel %-32s %s" % (fn, why), file=sys.stderr)
    for name, b in bad_buf:
        print("  %-24s asks bufs for %-16s which nothing allocates" % (name, b), file=sys.stderr)
    print("\nA kernel nobody dispatches, or a buffer nobody creates, is a subsystem that silently does\n"
          "nothing while every gate that names it stays green.", file=sys.stderr)
    sys.exit(1)

print("check_declared_and_dispatched: OK (%d kernels dispatched, %d buffers allocated)"
      % (len(loaded), len(allocated)))
PY
