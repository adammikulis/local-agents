#!/usr/bin/env bash
# =====================================================================================================
# DECLARED AND NEVER ASSIGNED — a field stuck at its initial value, silently disabling what it gates.
#
# Two of the worst defects in this project were this exact shape, and both were found by accident:
#
#   MaterialField3D.sea_level     declared 0.0, never written. Every consumer measuring "height above the
#                                 sea" measured height above the planet CENTRE. The aquifer's grain-size
#                                 gradient collapsed to one permeability planet-wide; cloud base and fog
#                                 base resolved to inside the mantle.
#   MaterialField3D._terrain_opts declared {}, never written. It is the solid-mask cache's key, so the
#                                 guard `if not _terrain_opts.is_empty()` was always false and the cache
#                                 had never once been used.
#
# Neither produced an error. Both produced a working-looking sim with a dead subsystem inside it, which is
# the failure mode this whole repo keeps hitting: not a crash, a plausible number.
#
# WHAT IT FLAGS. A `var` declared at class scope, read somewhere, and never assigned outside its
# declaration — no `x =`, `x +=`, no `.append`/`.resize`/`.fill`/`.clear` on it, and not an @export (the
# editor writes those) or a signal/const.
#
# EXIT CODES. 0 none · 1 found · 2 could not run.
# =====================================================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAP_FILE="$REPO_ROOT/docs/NEVER_ASSIGNED_CEILING"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
[ -d "$REPO_ROOT/addons/local_agents" ] || { echo "ERROR: source root missing." >&2; exit 2; }

python3 - "$REPO_ROOT" "$CAP_FILE" <<'PY'
import os, re, sys

root, cap_file = sys.argv[1], sys.argv[2]

DECL = re.compile(r"^var\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::[^=]*)?(=.*)?$")
# Anything that can put a value into it. `.get(` and `.size()` are reads, so they are not here.
MUTATE = ".append(.resize(.fill(.clear(.push_back(.insert(.erase(.set(.remove_at(.sort(.assign(".split("(")

def assigned_somewhere(name, body):
    if re.search(r"(?<![A-Za-z0-9_.])%s\s*(?:[-+*/|&^]|<<|>>)?=(?!=)" % re.escape(name), body):
        return True
    for m in MUTATE:
        if m and re.search(r"(?<![A-Za-z0-9_])%s\s*%s\(" % (re.escape(name), re.escape(m)), body):
            return True
    # passed somewhere it could be written into, or bound by reference in a loop
    if re.search(r"(?<![A-Za-z0-9_.])for\s+%s\b" % re.escape(name), body):
        return True
    if re.search(r"(?<![A-Za-z0-9_.])%s\s*\[[^\]]*\]\s*(?:[-+*/|&^]|<<|>>)?=(?!=)" % re.escape(name), body):
        return True
    return False

# THE WHOLE TREE IS THE SEARCH SPACE. A GDScript field is written through an instance reference from other
# files — `c.is_male = true`, `_f._solid = mask` — so a per-file scan reports fields that are assigned
# constantly. That mistake made the first two drafts of this gate report 126 and then 31, nearly all noise.
CORPUS = []
for dp0, dns0, fns0 in os.walk(os.path.join(root, "addons", "local_agents")):
    dns0[:] = [d for d in dns0 if d not in (".godot", "thirdparty")]
    for fn0 in fns0:
        if fn0.endswith((".gd", ".tscn", ".tres")):
            try:
                CORPUS.append(open(os.path.join(dp0, fn0), errors="replace").read())
            except OSError:
                pass
ALL = "\n".join(CORPUS)

def written_anywhere(name):
    # `x =`, `self.x =`, `obj.x =`, `x[...] =`, and the mutators — anywhere in the tree.
    if re.search(r"(?<![A-Za-z0-9_])\.?%s\s*(?:[-+*/|&^]|<<|>>)?=(?!=)" % re.escape(name), ALL):
        return True
    if re.search(r"(?<![A-Za-z0-9_])\.?%s\s*\[[^\]]*\]\s*(?:[-+*/|&^]|<<|>>)?=(?!=)" % re.escape(name), ALL):
        return True
    for m in MUTATE:
        if m and re.search(r"(?<![A-Za-z0-9_])\.?%s\s*%s\(" % (re.escape(name), re.escape(m)), ALL):
            return True
    if re.search(r'(?<![A-Za-z0-9_])set\(\s*"%s"' % re.escape(name), ALL):
        return True
    return False

hits = []
for dp, dns, fns in os.walk(os.path.join(root, "addons", "local_agents")):
    dns[:] = [d for d in dns if d not in (".godot", "thirdparty")]
    for fn in sorted(fns):
        if not fn.endswith(".gd"):
            continue
        path = os.path.join(dp, fn)
        rel = os.path.relpath(path, root)
        try:
            src = open(path, errors="replace").read()
        except OSError:
            continue
        lines = src.splitlines()
        for n, line in enumerate(lines, 1):
            if line[:1] in (" ", "\t"):
                continue
            s = line.strip()
            if s.startswith("@export") or s.startswith("@onready"):
                continue
            if n >= 2 and lines[n - 2].strip().startswith("@export"):
                continue
            m = DECL.match(s)
            if not m:
                continue
            name, init = m.group(1), (m.group(2) or "")
            # A declaration that already holds a real value is not the defect; the defect is a DEFAULT that
            # nothing ever replaces.
            init_v = init.lstrip("=").strip()
            if init_v and init_v not in ("null", "0", "0.0", "\"\"", "{}", "[]", "false",
                                         "Vector2.ZERO", "Vector3.ZERO", "Color()",
                                         "PackedFloat32Array()", "PackedInt32Array()",
                                         "PackedByteArray()", "PackedStringArray()", "RID()",
                                         "Callable()", "Dictionary()", "Array()"):
                continue
            body = "\n".join(l for i, l in enumerate(lines, 1) if i != n)
            if written_anywhere(name):
                continue
            if not re.search(r"(?<![A-Za-z0-9_.])%s\b" % re.escape(name), body):
                continue  # never read either: that is dead code, a different gate's job
            hits.append((rel, n, name, s[:72]))

print("NEVER_ASSIGNED={\"count\":%d}" % len(hits))
for rel, n, name, s in hits:
    print("  %s:%d  %s" % (rel, n, s))

cap = None
if os.path.exists(cap_file):
    for ln in open(cap_file):
        ln = ln.strip()
        if ln and not ln.startswith("#"):
            cap = int(ln); break
if cap is None:
    print("\nERROR: no ceiling. Write the current count to docs/NEVER_ASSIGNED_CEILING.", file=sys.stderr)
    sys.exit(2)
if len(hits) > cap:
    print("\n%d fields are stuck at their initial value against a ceiling of %d. Each one silently disables"
          % (len(hits), cap))
    print("whatever reads it. Assign it, or delete it and the code that reads it.")
    sys.exit(1)
if len(hits) < cap:
    print("NOTE  %d below the ceiling — lower docs/NEVER_ASSIGNED_CEILING to %d." % (cap - len(hits), len(hits)))
print("check_never_assigned: OK")
PY
