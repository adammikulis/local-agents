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
# THREE CLASSES, in rising order of how much they cost.
#   COPIES    identical after renaming. A bug in it has to be found N times.
#   SHAPE     identical ALGEBRA carrying different NUMBERS. Not at risk of drifting — already drifted.
#   FRAGMENT  a stretch repeated INLINE inside longer bodies. This is the class the kernels are made of:
#             the column walks and the buoyancy laws are fragments of 200-line main() bodies, not
#             functions of their own, so whole-function hashing is structurally blind to them.
#
# HOW. Each body is normalised — comments stripped, whitespace collapsed, every identifier that is not a
# keyword or a call replaced by a placeholder — then hashed with its numbers and again with them replaced
# by `#`. Short bodies are ignored: a two-line getter repeating is not a smell.
#
# BOTH LANGUAGES. .gd bodies are indentation-delimited, .glsl/.glsli bodies are brace-delimited.
#
# THIS GATE DOES NOT SAY "DELETE THE COPIES". It says: these N are one thing, decide what that thing is.
# The answer is usually a parameterised module and a record per case.
#
# EXIT CODES. 0 at or under every ceiling · 1 over any · 2 could not run.
# =====================================================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAP_FILE="$REPO_ROOT/docs/DUPLICATE_LOGIC_CEILING"
SHAPE_CAP_FILE="$REPO_ROOT/docs/DUPLICATE_SHAPE_CEILING"
FRAG_CAP_FILE="$REPO_ROOT/docs/DUPLICATE_FRAGMENT_CEILING"
MIN_LINES="${LA_DUP_MIN_LINES:-6}"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not on PATH — a gate that cannot run FAILS." >&2; exit 2; }
[ -d "$REPO_ROOT/addons/local_agents" ] || { echo "ERROR: source root missing." >&2; exit 2; }

python3 - "$REPO_ROOT" "$CAP_FILE" "$SHAPE_CAP_FILE" "$FRAG_CAP_FILE" "$MIN_LINES" <<'PY'
import os, re, sys, hashlib, collections

root, cap_file, shape_cap_file, frag_cap_file = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
min_lines = int(sys.argv[5])

KEYWORDS = set("""if elif else for while match return break continue pass and or not in is as var const func
static void bool int float String Vector2 Vector3 Color Array Dictionary PackedFloat32Array PackedInt32Array
PackedByteArray PackedStringArray PackedFloat64Array true false null self super range len min max abs clamp
clampf minf maxf absf sqrt pow exp log sin cos tan atan atan2 floor ceil round snappedf push_error
push_warning print
vec2 vec3 vec4 ivec2 ivec3 ivec4 uvec2 uvec3 uvec4 mat2 mat3 mat4 uint double inout
mix step smoothstep fract mod normalize length dot cross reflect refract inversesqrt sign
imageLoad imageStore barrier discard layout uniform buffer shared restrict readonly writeonly""".split())

IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
NUM = re.compile(r"\b\d+(?:\.\d*)?(?:[eE][-+]?\d+)?\b")


def normalise(body, ext):
    out = []
    for raw in body:
        line = re.sub(r"#.*$", "", raw) if ext == ".gd" else re.sub(r"//.*$", "", raw)
        line = line.strip()
        if not line or line in ("{", "}"):
            continue

        # An identifier NOT followed by "(" is data; rename it. A call keeps its name, because which
        # function you call is the algorithm, and which local you named it into is not.
        def sub(m, _line=line):
            name = m.group(0)
            if name in KEYWORDS:
                return name
            end = m.end()
            if end < len(_line) and _line[end] == "(":
                return name
            return "_"
        out.append(IDENT.sub(sub, line))
    return out


def bodies_gd(lines):
    """Indentation-delimited: a body runs to the next top-level func."""
    cur, start, body = None, 0, []
    for n, line in enumerate(lines, 1):
        m = re.match(r"^(?:static\s+)?func\s+([A-Za-z_][A-Za-z0-9_]*)", line)
        if m:
            if cur:
                yield cur, start, body
            cur, start, body = m.group(1), n, []
        elif cur is not None:
            body.append(line)
    if cur:
        yield cur, start, body


GLSL_FUNC = re.compile(r"^\s*(?:[A-Za-z_]\w*\s+)+([A-Za-z_]\w*)\s*\([^;{]*\)\s*\{?\s*$")


def bodies_glsl(lines):
    """Brace-delimited. Enter on a definition line, leave when the brace depth returns to zero."""
    i, n = 0, len(lines)
    while i < n:
        m = GLSL_FUNC.match(lines[i])
        if not m or lines[i].lstrip().startswith(("//", "#")):
            i += 1
            continue
        j, depth = i, lines[i].count("{") - lines[i].count("}")
        if "{" not in lines[i]:
            j = i + 1
            while j < n and not lines[j].strip():
                j += 1
            if j >= n or "{" not in lines[j]:
                i += 1
                continue
            depth = lines[j].count("{") - lines[j].count("}")
        start, body = i + 1, []
        j += 1
        while j < n and depth > 0:
            depth += lines[j].count("{") - lines[j].count("}")
            if depth > 0:
                body.append(lines[j])
            j += 1
        yield m.group(1), start, body
        i = j


exact = collections.defaultdict(list)
shape = collections.defaultdict(list)
units = []
for dp, dns, fns in os.walk(os.path.join(root, "addons", "local_agents")):
    dns[:] = [d for d in dns if d not in (".godot", "thirdparty")]
    for fn in sorted(fns):
        ext = os.path.splitext(fn)[1]
        if ext not in (".gd", ".glsl", ".glsli"):
            continue
        path = os.path.join(dp, fn)
        rel = os.path.relpath(path, root)
        try:
            lines = open(path, errors="replace").read().splitlines()
        except OSError:
            continue
        for name, start, body in (bodies_gd(lines) if ext == ".gd" else bodies_glsl(lines)):
            if len(body) < min_lines:
                continue
            norm = normalise(body, ext)
            if len(norm) < min_lines:
                continue
            joined = "\n".join(norm)
            units.append((rel, start, name, norm))
            row = (rel, start, name, len(norm))
            exact[hashlib.sha1(joined.encode()).hexdigest()[:12]].append(row)
            shape[hashlib.sha1(NUM.sub("#", joined).encode()).hexdigest()[:12]].append(row)


def cross_of(groups):
    # Copies inside ONE file are a different (smaller) problem; the expensive shape is across files.
    return {h: v for h, v in groups.items() if len(v) > 1 and len({x[0] for x in v}) > 1}


cross = cross_of(exact)
total = sum(len(v) - 1 for v in cross.values())

# A shape group whose members are already an exact group is a copy, not drift — counted once, as a copy.
exact_members = {(r, s) for v in cross.values() for r, s, _, _ in v}
shape_cross = {}
for h, v in cross_of(shape).items():
    fresh = [x for x in v if (x[0], x[1]) not in exact_members]
    if len(fresh) > 1 and len({x[0] for x in fresh}) > 1:
        shape_cross[h] = fresh
shape_total = sum(len(v) - 1 for v in shape_cross.values())

FRAG_WINDOW = int(os.environ.get("LA_DUP_FRAGMENT_WINDOW", "7"))
# SCOPED TO THE SUBSTRATE. Over the whole tree the fragment pass reports ~145 groups of signal-wiring and
# dictionary-building boilerplate, and a gate that cries wolf gets bypassed. Inside sim/material a repeated
# stretch of arithmetic is a physical law written twice, which is the thing worth failing on.
FRAG_SCOPE = os.environ.get("LA_DUP_FRAGMENT_SCOPE", "sim/material")

seen = collections.defaultdict(set)
for rel, start, name, norm in units:
    if FRAG_SCOPE not in rel:
        continue
    for i in range(len(norm) - FRAG_WINDOW + 1):
        h = hashlib.sha1(NUM.sub("#", "\n".join(norm[i:i + FRAG_WINDOW])).encode()).hexdigest()[:12]
        seen[h].add((rel, name, start + i))

frag, claimed = [], set()
for h, v in sorted(seen.items(), key=lambda kv: -len(kv[1])):
    if len({x[0] for x in v}) < 2:
        continue
    # Overlapping windows re-report one region; keep a single row per set of (file, function).
    key = frozenset((x[0], x[1]) for x in v)
    if key in claimed:
        continue
    claimed.add(key)
    frag.append((h, sorted(v)))
frag_total = sum(len({(x[0], x[1]) for x in v}) - 1 for _, v in frag)

print('DUPLICATE_LOGIC={"groups":%d,"redundant_copies":%d,"shape_groups":%d,"shape_copies":%d,'
      '"fragment_groups":%d,"fragment_copies":%d}'
      % (len(cross), total, len(shape_cross), shape_total, len(frag), frag_total))

for label, g in (("COPIES (identical after renaming)", cross),
                 ("SHAPE (same algebra, DIFFERENT NUMBERS — these have already drifted)", shape_cross)):
    if not g:
        continue
    print("\n%s" % label)
    for h, v in sorted(g.items(), key=lambda kv: -len(kv[1]))[:10]:
        print("  %d sites, %d lines:" % (len(v), v[0][3]))
        for rel, start, name, _ in v[:5]:
            print("      %s:%d  %s()" % (rel, start, name))

if frag:
    print("\nFRAGMENTS (%d statements repeated inline under %s/, numbers ignored)" % (FRAG_WINDOW, FRAG_SCOPE))
    for h, v in frag[:12]:
        by_fn = {}
        for rel, name, line in v:
            by_fn.setdefault((rel, name), line)
        print("  %d sites:" % len(by_fn))
        for (rel, name), line in sorted(by_fn.items())[:6]:
            print("      %s:~%d  in %s()" % (rel, line, name))


def read_cap(path):
    if not os.path.exists(path):
        return None
    for ln in open(path):
        ln = ln.strip()
        if ln and not ln.startswith("#"):
            return int(ln)
    return None


caps = [("COPIES", total, read_cap(cap_file), cap_file, "DUPLICATE_LOGIC_CEILING"),
        ("SHAPE", shape_total, read_cap(shape_cap_file), shape_cap_file, "DUPLICATE_SHAPE_CEILING"),
        ("FRAGMENT", frag_total, read_cap(frag_cap_file), frag_cap_file, "DUPLICATE_FRAGMENT_CEILING")]
missing = [f for _, _, c, f, _ in caps if c is None]
if missing:
    print("\nERROR: no ceiling in %s." % ", ".join(missing), file=sys.stderr)
    sys.exit(2)

bad = False
for label, got, cap, _, name in caps:
    if got > cap:
        print("\n%s: %d against a ceiling of %d." % (label, got, cap))
        if label == "COPIES":
            print("Each group is ONE algorithm written N times, and a bug in it has to be found N times.")
        elif label == "SHAPE":
            print("Same algebra, different constants. One of them is wrong and nothing says which.")
        else:
            print("A law repeated inline. Lift it into a shared helper so there is one place to correct.")
        bad = True
if bad:
    sys.exit(1)
for label, got, cap, _, name in caps:
    if got < cap:
        print("NOTE  %d below %s — lower it to %d." % (cap - got, name, got))
print("check_duplicate_logic: OK")
PY
