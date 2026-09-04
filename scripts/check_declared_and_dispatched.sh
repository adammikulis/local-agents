#!/usr/bin/env bash
# DECLARED IS NOT DISPATCHED, AND NAMED IS NOT ALLOCATED. A kernel nobody dispatches, or a buffer
# nobody creates, is a subsystem that silently does nothing while every gate naming it stays green.
# 1 every .glsl in kernels3d/ is dispatched: an ordinary one by a pass in PASS_SCRIPTS, a selftest one
# by a gate or a test, because a kernel nothing loads is one whose compile error nobody sees.
# 2 every buffer a pass takes from `bufs` is allocated. Which slots those are comes from
# material/Bindings.gd. EXIT 0 clean · 1 a violation · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib_require.sh
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
if declare -f require_tool >/dev/null 2>&1; then
  require_tool python3
elif ! command -v python3 >/dev/null 2>&1; then
  echo "check_declared_and_dispatched: python3 absent." >&2
  exit 2
fi

python3 - "$ROOT" <<'PY'
import os, re, sys
sys.dont_write_bytecode = True
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "scripts"))
import lib_bindings as LB

MAT = LB.MATERIAL
DRIVER = os.path.join(MAT, "MaterialSphereGPU3D.gd")
CHANNELS = os.path.join(MAT, "Channels.gd")
# Where a kernel that no field pass dispatches may legitimately be loaded from.
OUTSIDE = [os.path.join(root, "scripts"), os.path.join(root, "addons/local_agents/tests")]

try:
    rows = LB.slots()
    declared = LB.in_kernel()
    driver = LB.read(DRIVER)
    chan = LB.read(CHANNELS)
except (LB.Missing, OSError) as err:
    print("check_declared_and_dispatched: %s" % err, file=sys.stderr)
    sys.exit(2)

m = re.search(r"PASS_SCRIPTS[^=]*=\s*\[(.*?)\]", driver, re.S)
if not m:
    print("check_declared_and_dispatched: no PASS_SCRIPTS in the driver.", file=sys.stderr)
    sys.exit(2)
registered = set(re.findall(r"sphere_passes/(\w+)\.gd", m.group(1)))
if not registered:
    print("check_declared_and_dispatched: PASS_SCRIPTS parsed to zero passes.", file=sys.stderr)
    sys.exit(2)

pass_src = {fn[:-3]: LB.read(os.path.join(LB.PASSES, fn)) for fn in LB.pass_files()}

# --- 1. a kernel nobody dispatches --------------------------------------------------------------------
loaded = {}
for name, src in pass_src.items():
    for k in re.findall(r"kernels3d/(\w+)\.glsl", src):
        loaded.setdefault(k, set()).add(name)

outside_loads = set()
for tree in OUTSIDE:
    if not os.path.isdir(tree):
        print("check_declared_and_dispatched: MISSING %s — a kernel loaded only from there would read "
              "as loaded by nobody." % os.path.relpath(tree, root), file=sys.stderr)
        sys.exit(2)
    for dirpath, _dirs, names in os.walk(tree):
        for n in names:
            if n.endswith(".gd") or n.endswith(".sh") or n.endswith(".py"):
                outside_loads |= set(re.findall(r"kernels3d/(\w+)\.glsl",
                                                LB.read(os.path.join(dirpath, n))))

bad_kernel = []
for fn in LB.kernel_files():
    stem = fn[:-5]
    owners = loaded.get(stem, set())
    if owners & registered:
        continue
    # A selftest kernel exists to be COMPILED and read back by the gate that dispatches it.
    if stem in outside_loads:
        continue
    if not owners:
        bad_kernel.append((fn, "no pass, gate or test loads it"))
    else:
        bad_kernel.append((fn, "loaded only by %s, which is not in PASS_SCRIPTS"
                           % ", ".join(sorted(owners))))

# --- 2. a pass naming a buffer nothing allocates -------------------------------------------------------
rows_m = re.search(r"static func rows\(\).*?\n\treturn \{(.*?)\n\t\}", chan, re.S)
derived = re.search(r"static func derived_buffers\(\).*?\n\treturn PackedStringArray\(\[(.*?)\]\)",
                    chan, re.S)
allocated = set(re.findall(r'"(\w+)":', rows_m.group(1))) if rows_m else set()
allocated |= set(re.findall(r'"(\w+)"', derived.group(1))) if derived else set()
allocated |= set(re.findall(r'_bufs\["(\w+)"\]\s*=', driver))
classes = LB.sim_classes()


def keys_of(src):
    """`const KEYS: Dictionary = {"a": "buf", ...}` -> field -> buffer name."""
    m = re.search(r"const KEYS: Dictionary = \{(.*?)\}", src, re.S)
    return dict(re.findall(r'"(\w+)"\s*:\s*"(\w+)"', m.group(1))) if m else {}


def declared_by(src):
    """Every buffer name a `buffers()` / `_buffers()` body names, its KEYS fields resolved."""
    out = set()
    keys = keys_of(src)
    consts = dict(re.findall(r'const\s+(\w+)\s*:\s*String\s*=\s*"(\w+)"', src))
    for body in re.findall(r"func _?buffers\([^)]*\)[^\n]*\n((?:[ \t].*\n|\n)*)", src):
        out |= set(re.findall(r'"(\w+)"', body))
        for field in re.findall(r"KEYS\.(\w+)", body):
            if field not in keys:
                return None
            out.add(keys[field])
        for ident in re.findall(r"(\w+)\s*:", body):
            if ident in consts:
                out.add(consts[ident])
    return out


# A pass declares buffers of its own and the DRIVER allocates them (_allocate_declared). A pass may
# hand that job to another class's `buffers()`, so follow the call rather than calling those absent.
unfollowed = []
for nm, src in pass_src.items():
    if nm not in registered:
        continue
    preloads = dict(re.findall(r'const\s+(\w+)\s*:\s*GDScript\s*=\s*preload\("([^"]+)"\)', src))
    got = declared_by(src)
    if got is None:
        unfollowed.append("%s names a KEYS field its own class does not declare" % nm)
        continue
    allocated |= got
    body = re.search(r"func _buffers\([^)]*\)[^\n]*\n((?:[ \t].*\n|\n)*)", src)
    for owner in (re.findall(r"(\w+)\.buffers\(", body.group(1)) if body else []):
        other = None
        if owner in preloads:
            path = os.path.join(root, preloads[owner].replace("res://", ""))
            other = LB.read(path) if os.path.isfile(path) else None
        elif owner in classes:
            other = classes[owner]
        got = declared_by(other) if other is not None else None
        if got is None:
            unfollowed.append("%s allocates through %s.buffers(), which the gate cannot read" % (nm, owner))
            continue
        allocated |= got
if unfollowed:
    print("check_declared_and_dispatched: an allocation the gate cannot follow is one it would call "
          "missing.", file=sys.stderr)
    for u in sorted(set(unfollowed)):
        print("  " + u, file=sys.stderr)
    sys.exit(2)
if not allocated:
    print("check_declared_and_dispatched: no buffers found — the gate has no subject.", file=sys.stderr)
    sys.exit(2)

bad_buf = []
unresolved = []
asked_total = 0
for fn in LB.pass_files():
    name = fn[:-3]
    if name not in registered:
        continue
    sets, un = LB.pass_sets(fn, classes)
    unresolved += un
    # A slot the kernel declares and the pass does not supply itself is one the DRIVER must have
    # allocated under that name.
    from_bufs = set()
    for kernel, own in sets:
        if kernel not in declared:
            bad_buf.append((name, kernel, "is not a kernel Bindings.gd knows"))
            continue
        from_bufs |= set(declared[kernel]) - set(own)
    asked = from_bufs | set(re.findall(r'_(?:single|pair|half)\(\s*bufs\s*,\s*"(\w+)"',
                                       pass_src[name]))
    asked_total += len(asked)
    for b in sorted(asked - allocated):
        bad_buf.append((name, b, "which nothing allocates"))

if unresolved:
    print("check_declared_and_dispatched: a buffer list the gate cannot read is one it cannot check.",
          file=sys.stderr)
    for u in sorted(set(unresolved)):
        print("  " + u, file=sys.stderr)
    sys.exit(2)
if asked_total == 0:
    print("check_declared_and_dispatched: no pass asked for a buffer — the gate has no subject.",
          file=sys.stderr)
    sys.exit(2)

if bad_kernel or bad_buf:
    print("check_declared_and_dispatched: FAILED", file=sys.stderr)
    for fn, why in bad_kernel:
        print("  kernel %-32s %s" % (fn, why), file=sys.stderr)
    for name, b, why in bad_buf:
        print("  %-24s asks bufs for %-18s %s" % (name, b, why), file=sys.stderr)
    print("\nA kernel nobody dispatches, or a buffer nobody creates, is a subsystem that silently does\n"
          "nothing while every gate that names it stays green.", file=sys.stderr)
    sys.exit(1)

print("check_declared_and_dispatched: OK (%d kernels dispatched, %d buffers allocated, %d asked)"
      % (len(LB.kernel_files()), len(allocated), asked_total))
PY
