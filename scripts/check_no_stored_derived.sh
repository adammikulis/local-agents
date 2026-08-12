#!/usr/bin/env bash
# A channel is independent STATE or it is DERIVED. A derived channel may not have a buffer.
#
# A value fully determined by other channels plus a law is a cache, and a cache can disagree with its
# source: the moisture channel and sat_mass_frac held one fact in units differing by the molar density of
# water. Every row says which it is, and a derived row names the law.
#
# EXIT 0 clean · 1 a row is undeclared or a derived row is stored · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CH="${LA_CH:-$ROOT/addons/local_agents/sim/material/Channels.gd}"
[ -f "$CH" ] || { echo "check_no_stored_derived: MISSING $CH" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "check_no_stored_derived: python3 absent." >&2; exit 2; }

python3 - "$CH" <<'PY'
import re, sys
src = open(sys.argv[1]).read()

rows = re.findall(r'^\s*"(\w+)":\s*\{(.+?)\},?\s*$', src, re.M)
if not rows:
    print("check_no_stored_derived: no channel rows found — the gate has no subject.", file=sys.stderr)
    sys.exit(2)

undeclared, stored_derived = [], []
for name, body in rows:
    kind = re.search(r'"kind":\s*"(\w+)"', body)
    buf = re.search(r'"buffer":\s*"(\w*)"', body)
    if not kind:
        undeclared.append(name)
        continue
    if kind.group(1) == "derived":
        if buf and buf.group(1):
            stored_derived.append((name, buf.group(1)))
        if not re.search(r'"from":\s*"[^"]+"', body):
            undeclared.append(name + " (derived, but names no law)")

if undeclared or stored_derived:
    print("check_no_stored_derived: FAILED", file=sys.stderr)
    for n in undeclared:
        print("  %-16s declares no `kind` of \"state\" or \"derived\"" % n, file=sys.stderr)
    for n, b in stored_derived:
        print("  %-16s is derived and still has a %s buffer" % (n, b), file=sys.stderr)
    print("\nA derived value in a buffer is a cache, and a cache can disagree with what derives it.",
          file=sys.stderr)
    sys.exit(1)
print("check_no_stored_derived: OK (%d channels)" % len(rows))
PY
