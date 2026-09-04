#!/usr/bin/env bash
# DECLARED AND NEVER ASSIGNED — a field stuck at its initial value, silently disabling what it gates.
# Flags a class-scope `var` that is read somewhere and assigned nowhere in the tree: no `x =`, `x +=`,
# no `.append`/`.resize`/`.fill`/`.clear` on it, not an @export (the editor writes those), not a const.
# EXIT 0 none · 1 found · 2 could not run.
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
MUTATE = "append resize fill clear push_back insert erase set remove_at sort assign".split()
NAME = r"[A-Za-z_][A-Za-z0-9_]*"
STORE = r"\s*(?:[-+*/|&^]|<<|>>)?=(?!=)"
# ONE PASS PER SHAPE OVER THE TREE, capturing the name written, rather than one scan per candidate.
WRITE_RE = [
    re.compile(r"(?<![A-Za-z0-9_])\.?(%s)%s" % (NAME, STORE)),
    re.compile(r"(?<![A-Za-z0-9_])\.?(%s)\s*\[[^\]]*\]%s" % (NAME, STORE)),
    re.compile(r"(?<![A-Za-z0-9_])\.?(%s)\s*\.(?:%s)\(" % (NAME, "|".join(MUTATE))),
    re.compile(r'set\(\s*"(%s)"' % NAME),
]
READ_RE = re.compile(r"(?<![A-Za-z0-9_.])(%s)\b" % NAME)

# THE WHOLE TREE IS THE SEARCH SPACE. A GDScript field is written through an instance reference from other
# files — `c.is_male = true`, `_f._solid = mask` — so a per-file scan reports fields that are assigned
# constantly. That mistake made the first two drafts of this gate report 126 and then 31, nearly all noise.
SOURCE = {}
CORPUS = []
for dp, dns, fns in os.walk(os.path.join(root, "addons", "local_agents")):
    dns[:] = [d for d in dns if d not in (".godot", "thirdparty")]
    for fn in sorted(fns):
        if not fn.endswith((".gd", ".tscn", ".tres")):
            continue
        path = os.path.join(dp, fn)
        try:
            text = open(path, errors="replace").read()
        except OSError:
            continue
        CORPUS.append(text)
        if fn.endswith(".gd"):
            SOURCE[path] = text
ALL = "\n".join(CORPUS)

WRITTEN = set()
for rx in WRITE_RE:
    WRITTEN.update(m.group(1) for m in rx.finditer(ALL))


def read_lines(text):
    """name -> the line numbers it is read on, from one scan of the file."""
    starts = [0] + [i + 1 for i, ch in enumerate(text) if ch == "\n"]
    seen = {}
    line = 0
    for m in READ_RE.finditer(text):
        while line + 1 < len(starts) and starts[line + 1] <= m.start():
            line += 1
        seen.setdefault(m.group(1), set()).add(line + 1)
    return seen


BARE = ("null", "0", "0.0", "\"\"", "{}", "[]", "false",
        "Vector2.ZERO", "Vector3.ZERO", "Color()",
        "PackedFloat32Array()", "PackedInt32Array()",
        "PackedByteArray()", "PackedStringArray()", "RID()",
        "Callable()", "Dictionary()", "Array()")

hits = []
for path in sorted(SOURCE):
    src = SOURCE[path]
    rel = os.path.relpath(path, root)
    lines = src.splitlines()
    reads = None
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
        if init_v and init_v not in BARE:
            continue
        if name in WRITTEN:
            continue
        if reads is None:
            reads = read_lines(src)
        # Read nowhere but its own declaration is dead code, which is a different gate's job.
        if reads.get(name, set()) - {n}:
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
