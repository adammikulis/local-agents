#!/usr/bin/env bash
# =====================================================================================================
# DUPLICATE LOGIC — the same algorithm written N times, found by shape rather than by noticing.
#
# Every expensive defect in this project so far has been one bug written N times, and each was found by
# accident: rc_of in five copies and four incompatible versions, so a snowy cell was mostly air to one
# kernel and energy was created on every exchange between them. Four conservation ledgers, so a probe read
# with a silent mirror fallback got fixed in one at a time. Five radial column walks with five different
# stop rules. Two placements of standing water, one called "lakes" and one called "the ocean". Three
# buoyancy laws for one Archimedean statement.
#
# A person will not spot these: the copies live in different files, they were written months apart, and
# each looks reasonable alone. A hash does spot them.
#
# HOW. Each function body is normalised — comments stripped, whitespace collapsed, every identifier that is
# not a keyword or a call replaced by a placeholder — then hashed. Bodies sharing a hash are the same
# algorithm regardless of what their variables were called. Short bodies are ignored: a two-line getter
# repeating is not a smell.
#
# THIS GATE DOES NOT SAY "DELETE THE COPIES". It says: these N are one thing, decide what that thing is.
# The answer is usually a parameterised module and a record per case.
#
# EXIT CODES. 0 at or under the ceiling · 1 over · 2 could not run.
# =====================================================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAP_FILE="$REPO_ROOT/docs/DUPLICATE_LOGIC_CEILING"
MIN_LINES="${LA_DUP_MIN_LINES:-6}"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
[ -d "$REPO_ROOT/addons/local_agents" ] || { echo "ERROR: source root missing." >&2; exit 2; }

python3 - "$REPO_ROOT" "$CAP_FILE" "$MIN_LINES" <<'PY'
import os, re, sys, hashlib, collections

root, cap_file, min_lines = sys.argv[1], sys.argv[2], int(sys.argv[3])

KEYWORDS = set("""if elif else for while match return break continue pass and or not in is as var const func
static void bool int float String Vector2 Vector3 Color Array Dictionary PackedFloat32Array PackedInt32Array
PackedByteArray PackedStringArray PackedFloat64Array true false null self super range len min max abs clamp
clampf minf maxf absf sqrt pow exp log sin cos tan atan atan2 floor ceil round snappedf push_error
push_warning print""".split())

IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

def normalise(body):
    out = []
    for line in body:
        line = re.sub(r"#.*$", "", line).strip()
        if not line:
            continue
        # An identifier NOT followed by "(" is data; rename it. A call keeps its name, because which
        # function you call is the algorithm, and which local you named it into is not.
        def sub(m):
            name = m.group(0)
            end = m.end()
            if name in KEYWORDS:
                return name
            if end < len(line) and line[end] == "(":
                return name
            return "_"
        out.append(IDENT.sub(sub, line))
    return out

groups = collections.defaultdict(list)
for dp, dns, fns in os.walk(os.path.join(root, "addons", "local_agents")):
    dns[:] = [d for d in dns if d not in (".godot", "thirdparty")]
    for fn in sorted(fns):
        if not fn.endswith(".gd"):
            continue
        path = os.path.join(dp, fn)
        rel = os.path.relpath(path, root)
        try:
            lines = open(path, errors="replace").read().splitlines()
        except OSError:
            continue
        cur, start, body = None, 0, []
        def flush():
            if cur and len(body) >= min_lines:
                norm = normalise(body)
                if len(norm) >= min_lines:
                    h = hashlib.sha1("\n".join(norm).encode()).hexdigest()[:12]
                    groups[h].append((rel, start, cur, len(norm)))
        for n, line in enumerate(lines, 1):
            m = re.match(r"^(?:static\s+)?func\s+([A-Za-z_][A-Za-z0-9_]*)", line)
            if m:
                flush()
                cur, start, body = m.group(1), n, []
            elif cur is not None:
                body.append(line)
        flush()

dups = {h: v for h, v in groups.items() if len(v) > 1}
# Copies inside ONE file are a different (smaller) problem; the expensive shape is across files.
cross = {h: v for h, v in dups.items() if len({x[0] for x in v}) > 1}
total = sum(len(v) - 1 for v in cross.values())

print("DUPLICATE_LOGIC={\"groups\":%d,\"redundant_copies\":%d}" % (len(cross), total))
for h, v in sorted(cross.items(), key=lambda kv: -len(kv[1]))[:10]:
    print("  %d copies, %d lines:" % (len(v), v[0][3]))
    for rel, start, name, _ in v[:5]:
        print("      %s:%d  %s()" % (rel, start, name))

cap = None
if os.path.exists(cap_file):
    for ln in open(cap_file):
        ln = ln.strip()
        if ln and not ln.startswith("#"):
            cap = int(ln); break
if cap is None:
    print("\nERROR: no ceiling. Write the current count to docs/DUPLICATE_LOGIC_CEILING.", file=sys.stderr)
    sys.exit(2)
if total > cap:
    print("\n%d redundant copies against a ceiling of %d. Each group is ONE algorithm written N times, and"
          % (total, cap))
    print("a bug in it has to be found N times. Parameterise it: one module, one record per case.")
    sys.exit(1)
if total < cap:
    print("NOTE  %d below the ceiling — lower docs/DUPLICATE_LOGIC_CEILING to %d." % (cap - total, total))
print("check_duplicate_logic: OK")
PY
