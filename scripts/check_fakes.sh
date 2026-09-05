#!/usr/bin/env bash
# EVERY STAND-IN THIS WORLD RUNS ON IS DECLARED, AND ONE WHOSE RUNG HAS LANDED IS GONE. Holds
# LAFakes.RECORDS, docs/FAKES.md and the guards in the code to each other, and fails the moment
# docs/PLAYABLE_RUNG reaches a record's replacing rung.
# EXIT 0 registry and code agree * 1 they do not * 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3

python3 - "$ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]
fakes_gd = os.path.join(root, "addons/local_agents/sim/LAFakes.gd")
fakes_md = os.path.join(root, "docs/FAKES.md")
ladder_cpp = os.path.join(root, "addons/local_agents/gdextensions/localagents/src/LAProcessSet.cpp")
playable = os.path.join(root, "docs/PLAYABLE_RUNG")
for p in (fakes_gd, fakes_md, ladder_cpp, playable):
    if not os.path.isfile(p):
        print("check_fakes: MISSING %s" % p, file=sys.stderr)
        sys.exit(2)

# The ladder's own order is the one place a rung name maps to a height.
rows = re.findall(r"\{\s*LAProcessSet::([A-Z_]+),\s*\"", open(ladder_cpp, errors="replace").read())
if not rows:
    print("check_fakes: LAProcessSet.cpp declares no LADDER rows", file=sys.stderr)
    sys.exit(2)
height = {name: i for i, name in enumerate(rows)}

green = -1
for line in open(playable, errors="replace"):
    s = line.strip()
    if s and not s.startswith("#"):
        green = int(s)
        break
if green < 0:
    print("check_fakes: docs/PLAYABLE_RUNG names no rung", file=sys.stderr)
    sys.exit(2)

src = open(fakes_gd, errors="replace").read()
body = src.split("const RECORDS", 1)[-1].split("\n]", 1)[0]
blocks = re.findall(r"\{(.*?)\},", body, re.S)
records = []
for b in blocks:
    def field(key):
        m = re.search(r'"%s":\s*"((?:[^"\\]|\\.)*)"' % key, b)
        return m.group(1).replace('\\"', '"') if m else None
    rung = re.search(r'"rung":\s*LAProcessSet\.([A-Z_]+)', b)
    records.append({"name": field("name"), "stands_in": field("stands_in"),
                    "rung": rung.group(1) if rung else None, "release": field("release"),
                    "file": field("file"), "expression": field("expression")})
if not records:
    print("check_fakes: LAFakes.gd declares no records", file=sys.stderr)
    sys.exit(2)

errors = []
declared = set()
for r in records:
    n = r["name"]
    if not n or not r["file"] or not r["expression"] or not r["stands_in"]:
        errors.append("a record is missing a field: %r" % r)
        continue
    declared.add(n)
    if bool(r["rung"]) == bool(r["release"]):
        errors.append("record '%s' must name exactly one of a ladder rung or a release" % n)
    elif r["rung"]:
        if r["rung"] not in height:
            errors.append("record '%s' names rung %s, which is not on the ladder" % (n, r["rung"]))
        # THE FAKE IS FORCED OUT BY ITS OWN RUNG LANDING. This is the whole point of the registry.
        elif green >= height[r["rung"]]:
            errors.append("record '%s' is replaced by rung %d (%s), which is GREEN: delete the fake and the record"
                          % (n, height[r["rung"]], r["rung"]))
    target = os.path.join(root, r["file"])
    if not os.path.isfile(target):
        errors.append("record '%s' names a file that does not exist: %s" % (n, r["file"]))
    elif r["expression"] not in open(target, errors="replace").read():
        errors.append("record '%s' names an expression its file does not contain: %s" % (n, r["expression"]))

# Every guard in the code is a record. A fake nobody declared is the failure this half catches.
used = {}
for dirpath, _, names in os.walk(os.path.join(root, "addons/local_agents")):
    for fn in names:
        if not fn.endswith(".gd") or fn == "LAFakes.gd":
            continue
        path = os.path.join(dirpath, fn)
        text = open(path, errors="replace").read()
        for m in re.finditer(r'LAFakes\.(?:stands_in|draw|give_back|held|capped)\([^)]*?"([a-z0-9_]+)"', text):
            used.setdefault(m.group(1), set()).add(os.path.relpath(path, root))
for name, where in sorted(used.items()):
    if name not in declared:
        errors.append("code fakes '%s' in %s and LAFakes has no record for it" % (name, ", ".join(sorted(where))))
for r in records:
    if r["name"] and r["name"] not in used:
        errors.append("record '%s' is declared and NO code stands in on it" % r["name"])

# The page a person reads must be the same list.
md = open(fakes_md, errors="replace").read()
md_rows = re.findall(r"^\|\s*`([a-z0-9_]+)`\s*\|([^|]*)\|\s*`([^`]+)`\s*\|", md, re.M)
md_names = [n for n, _, _ in md_rows]
if len(md_names) != len(set(md_names)):
    errors.append("docs/FAKES.md lists a fake twice")
for n, _, until in md_rows:
    if n not in declared:
        errors.append("docs/FAKES.md carries a row '%s' that LAFakes has no record for" % n)
    else:
        rec = next(r for r in records if r["name"] == n)
        want = rec["rung"] or rec["release"]
        if until != want:
            errors.append("docs/FAKES.md says '%s' is replaced by %s; LAFakes says %s" % (n, until, want))
for n in sorted(declared):
    if n not in md_names:
        errors.append("LAFakes declares '%s' and docs/FAKES.md has no row for it" % n)

if errors:
    for e in errors:
        print("  ERROR " + e, file=sys.stderr)
    print("check_fakes: FAIL (%d error(s))" % len(errors))
    sys.exit(1)
print("check_fakes: OK (%d fake(s) declared, all below the green rung %d)" % (len(records), green))
PY
