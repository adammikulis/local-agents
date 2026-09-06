#!/usr/bin/env bash
# TWO BUFFERS ON ONE BINDING NUMBER COMPILE, AND THE LATER WRITE WINS. material/Bindings.gd is the one
# place a binding number is written; this holds everything else to it.
# 1 bindings.glsli is what SLOT would emit · 2 no kernel writes a binding as an integer, and every slot
# it declares is in SLOT · 3 no pass writes a uniform-set index as an integer · 4 IN_KERNEL and the
# kernels agree both ways · 5 no unit declares one number twice · 6 every pass calls set_for with the
# kernel it loads and supplies only slots that kernel declares. 0 clean · 1 a collision · 2 cannot run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib_require.sh
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
if declare -f require_tool >/dev/null 2>&1; then
  require_tool python3
elif ! command -v python3 >/dev/null 2>&1; then
  echo "check_binding_collisions: python3 absent." >&2
  exit 2
fi

python3 - "$ROOT" <<'PY'
import os, sys
from collections import defaultdict
sys.dont_write_bytecode = True
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "scripts"))
import lib_bindings as LB
import gen_bindings

try:
    rows = LB.slots()
    declared = LB.in_kernel()
except (LB.Missing, OSError) as err:
    print("check_binding_collisions: %s" % err, file=sys.stderr)
    sys.exit(2)

binding_of = dict(rows)
bad = []
scanned = 0

# --- 1. the checked-in include is what SLOT would write today -----------------------------------------
try:
    if open(LB.GLSLI_OUT, encoding="utf-8").read() != gen_bindings.glsli_text():
        bad.append("kernels3d/bindings.glsli is stale — run scripts/gen_bindings.py")
except OSError:
    print("check_binding_collisions: kernels3d/bindings.glsli is gone.", file=sys.stderr)
    sys.exit(2)

# --- 2 and 5. what each kernels3d file declares -------------------------------------------------------
missing = []
for fn in LB.kernel_files() + LB.include_files():
    if fn == os.path.basename(LB.GLSLI_OUT):
        continue
    for lit in LB.literals_in(fn):
        bad.append("%s writes `binding = %s` as an integer; use LA_BIND_<NAME>" % (fn, lit))
    for name, _origin in LB.declared_in(fn):
        scanned += 1
        if name not in binding_of:
            bad.append("%s declares LA_BIND_%s, which Bindings.gd's SLOT has no row for"
                       % (fn, name.upper()))

unit = {}
for fn in LB.kernel_files():
    entries = LB.unit_declared(fn, missing)
    unit[fn] = [name for name, _o in entries]
    seen = {}
    for name, origin in entries:
        b = binding_of.get(name)
        if b is None:
            continue
        if b in seen and seen[b][0] != name:
            bad.append("%s: %s (%s) and %s (%s) are both binding %d"
                       % (fn, seen[b][0], seen[b][1], name, origin, b))
        elif b in seen:
            bad.append("%s declares \"%s\" twice (%s and %s)" % (fn, name, seen[b][1], origin))
        else:
            seen[b] = (name, origin)

if missing:
    print("check_binding_collisions: cannot resolve an #include — the gate would under-count.",
          file=sys.stderr)
    for m in missing:
        print("  " + m, file=sys.stderr)
    sys.exit(2)

# --- 4. IN_KERNEL is what the kernels declare ---------------------------------------------------------
for fn in sorted(set(unit) | set(declared)):
    if fn not in unit:
        bad.append("IN_KERNEL names %s, which is not a kernel in kernels3d" % fn)
        continue
    if fn not in declared:
        bad.append("%s declares bindings and IN_KERNEL has no entry for it" % fn)
        continue
    have, want = set(unit[fn]), set(declared[fn])
    for name in sorted(want - have):
        bad.append("IN_KERNEL says %s declares \"%s\"; it does not" % (fn, name))
    for name in sorted(have - want):
        bad.append("%s declares \"%s\"; IN_KERNEL's list for it omits the slot" % (fn, name))

for name, _b in rows:
    if not any(name in v for v in declared.values()):
        bad.append("\"%s\" is in SLOT and no kernel declares it — a slot nothing reads" % name)

# --- 3 and 6. what each pass builds -------------------------------------------------------------------
classes = LB.sim_classes()
unresolved = []
for fn in LB.pass_files():
    for lit in LB.pass_literal_bindings(fn):
        bad.append("%s writes `[%s, ...]` as a uniform-set entry; use LABindings.set_for()" % (fn, lit))
    sets, un = LB.pass_sets(fn, classes)
    unresolved += un
    if not sets:
        continue
    kernel = LB.pass_kernel(fn)
    loaded = set([kernel] if isinstance(kernel, str) else (kernel or []))
    if not loaded:
        print("check_binding_collisions: %s builds a uniform set and loads no kernel — the gate cannot "
              "tell which kernel its slots must exist in." % fn, file=sys.stderr)
        sys.exit(2)
    loop_filled = set(LB.pass_looped(fn, classes))
    for named, own in sets:
        if named not in loaded:
            bad.append("%s loads %s and calls set_for(\"%s\") — it would bind another kernel's slots"
                       % (fn, ", ".join(sorted(loaded)), named))
            continue
        scanned += len(own)
        # A slot filled by walking a const list names no kernel; it is supplied to whichever of the
        # pass's kernels declares it, so only what the literal dictionary names is checked here.
        for name in sorted(set(own) - set(unit[named]) - loop_filled):
            bad.append("%s supplies \"%s\" to %s, which never declares it" % (fn, name, named))

if unresolved:
    print("check_binding_collisions: a uniform set the gate cannot read is a set it cannot check.",
          file=sys.stderr)
    for u in sorted(set(unresolved)):
        print("  " + u, file=sys.stderr)
    sys.exit(2)

if scanned == 0:
    print("check_binding_collisions: found no bindings — the gate has no subject.", file=sys.stderr)
    sys.exit(2)

if bad:
    print("check_binding_collisions: FAILED", file=sys.stderr)
    for b in sorted(set(bad)):
        print("  " + b, file=sys.stderr)
    print("\nTwo buffers on one binding number compile. The later write wins and the kernel reads the\n"
          "wrong quantity, silently, for as long as nobody notices. A slot a kernel declares and no\n"
          "pass fills is memory the kernel reads unwritten.", file=sys.stderr)
    sys.exit(1)

print("check_binding_collisions: OK (%d slots, %d declarations, no collisions)" % (len(rows), scanned))
PY
