#!/usr/bin/env bash
# check_model_parameters.sh exempts the authority files, so this holds them instead: a number in
# PhysicalConstants.gd or LABodySystem.cpp claims to be a MEASUREMENT, and one with no source is a value
# somebody chose. Counts the uncited, as a ratchet that may only fall. A citation names an author and year,
# a standards body or a data set; a named constant carries its own, on its line or directly over it.
#
# TWO SHAPES. A named declaration (`const NAME = <literal>`), and a bare literal INSIDE a function body or
# a table in the extension's body/seed sources -- LABodySeeds::spin_axis() returns today's obliquity as
# `Vector3(0.40, 0.92, 0.0)` and no declaration scan can see it. Whole numbers and one half are excluded:
# a count, a stoichiometric coefficient and a bisection are arithmetic, never measurements. Write `exact`
# in the comment for a number that is one by definition.
# EXIT 0 at or under the ceiling · 1 over it · 2 the gate could not run.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib_require.sh"
require_tool rg
require_tool python3
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CEILING_FILE="$ROOT/docs/UNCITED_AUTHORITY_CEILING"

FILES=(
	"$ROOT/addons/local_agents/sim/material/PhysicalConstants.gd"
	"$ROOT/addons/local_agents/gdextensions/localagents/src/LABodySystem.cpp"
	"$ROOT/addons/local_agents/gdextensions/localagents/src/LAWaterCurves.cpp"
	"$ROOT/addons/local_agents/gdextensions/localagents/src/LAMeltEos.cpp"
	"$ROOT/addons/local_agents/gdextensions/localagents/src/LAPhaseEos.cpp"
	"$ROOT/addons/local_agents/gdextensions/localagents/src/LASubstanceOptics.cpp"
)
for f in "${FILES[@]}"; do
	[ -f "$f" ] || { echo "check_cited_authority: MISSING $f" >&2; exit 2; }
done
[ -f "$CEILING_FILE" ] || { echo "check_cited_authority: MISSING $CEILING_FILE" >&2; exit 2; }
CEILING="$(rg -N -o '^[0-9]+$' "$CEILING_FILE" | head -1)"
[ -n "$CEILING" ] || { echo "check_cited_authority: $CEILING_FILE holds no bare integer" >&2; exit 2; }

# WHAT A CITATION LOOKS LIKE, once for both scans: an issuing body or data set, a name and a year, or
# `exact`. Four digits alone are not one: `1598 kJ/mol` restates a value, it does not source it.
export LA_CITE_RE="\\b(?:CODATA|IUPAC|IAU|NUBASE|HITRAN|NIST|IAPWS|JANAF|ISA|US Standard|IUGG|CRC)\\b|[A-Z](?:[^\\W\\d_]|['-])+(?:(?:,? (?:&|and) |, | )[A-Z](?:[^\\W\\d_]|['-])+)*(?: et al\\.?)?,? \\(?(?:1[6-9]|20)[0-9]{2}[a-z]?\\b|\\bexact"

CEILING="$CEILING" ROOT="$ROOT" python3 - "${FILES[@]}" <<'PY'
import os, re, sys

root, ceiling = os.environ["ROOT"], int(os.environ["CEILING"])
CITE = re.compile(os.environ["LA_CITE_RE"])
# LITERALS ONLY, in either language. A right-hand side built from other constants is held by its
# expression, not by a source, and demanding a citation for it was why this gate could not be trusted.
DECL = [re.compile(r"^const [A-Z_0-9]+: (?:float|int) = -?[0-9][0-9._eE+-]*[ \t]*(?:#.*)?$"),
        re.compile(r"^constexpr (?:double|int) [A-Z_0-9]+ = -?[0-9][0-9._eE+-]*;[ \t]*(?://.*)?$")]
COMMENT = re.compile(r"(//|#).*")
COMMENT_LINE = re.compile(r"^\s*(//|#)")

count = 0
uncited = []
for path in sys.argv[1:]:
    rel = os.path.relpath(path, root)
    lines = open(path, errors="replace").read().splitlines()
    for n, line in enumerate(lines, 1):
        if not any(rx.match(line) for rx in DECL):
            continue
        # ITS OWN: the comment on its line and the comment-only lines straight over it. COMMENT TEXT ONLY,
        # or a value would cite itself.
        above = n - 1
        while above >= 1 and COMMENT_LINE.match(lines[above - 1]):
            above -= 1
        own = COMMENT.search(line)
        block = "\n".join(lines[above:n - 1] + ([own.group(0)] if own else []))
        if not CITE.search(block):
            count += 1
            uncited.append("%s:%d  %s" % (rel, n, line))

if count > ceiling:
    print("\n".join(uncited), file=sys.stderr)
    print("FAIL  %d uncited constant(s) in the authority files, ceiling %d." % (count, ceiling),
          file=sys.stderr)
    print("      These files are exempt from check_model_parameters.sh because they are MEASUREMENTS.",
          file=sys.stderr)
    print("      Cite the source beside the value, or the exemption is a hole.", file=sys.stderr)
    raise SystemExit(1)
print('UNCITED_AUTHORITY={"count":%d}' % count)
print("check_cited_authority: declarations OK (%d uncited)" % count)
PY
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

# --- BARE LITERALS in the extension's body/seed sources ------------------------------------------------
BODY=(
	"$ROOT/addons/local_agents/gdextensions/localagents/src/LABodySystem.cpp"
	"$ROOT/addons/local_agents/gdextensions/localagents/src/LAPlanetTables.cpp"
	"$ROOT/addons/local_agents/gdextensions/localagents/src/LASubstanceOptics.cpp"
)
for f in "${BODY[@]}"; do
	[ -f "$f" ] || { echo "check_cited_authority: MISSING $f" >&2; exit 2; }
done
LIT_CEIL_FILE="$ROOT/docs/UNCITED_LITERAL_CEILING"
[ -f "$LIT_CEIL_FILE" ] || { echo "check_cited_authority: MISSING $LIT_CEIL_FILE" >&2; exit 2; }
LIT_CEILING="$(rg -N -o '^[0-9]+$' "$LIT_CEIL_FILE" | head -1)"
[ -n "$LIT_CEILING" ] || { echo "check_cited_authority: $LIT_CEIL_FILE holds no bare integer" >&2; exit 2; }
OUT_FILE="$(mktemp "${TMPDIR:-/tmp}/la_cited.XXXXXX")"
trap 'rm -f "$OUT_FILE"' EXIT
CEILING="$LIT_CEILING" ROOT="$ROOT" python3 - "${BODY[@]}" > "$OUT_FILE" <<'PY'
import math, os, re, sys

root, ceiling = os.environ["ROOT"], int(os.environ["CEILING"])
CITE = re.compile(os.environ["LA_CITE_RE"])
LIT = re.compile(r"(?<![\w.])(?:\d+\.\d*(?:[eE][-+]?\d+)?|\.\d+(?:[eE][-+]?\d+)?|\d+[eE][-+]?\d+)")
# A table's citation heads its rows, and a blank line ends the paragraph it heads.


def is_measurement(tok):
    v = float(tok)
    if v == round(v):
        return False           # a count, a stoichiometric coefficient, an order of magnitude
    if abs(v) == 0.5:
        return False           # a midpoint
    return abs(v - math.pi) > 1e-9


count, uncited = 0, []
for path in sys.argv[1:]:
    rel = os.path.relpath(path, root)
    lines = open(path, errors="replace").read().splitlines()
    for n, line in enumerate(lines, 1):
        code = line.split("//")[0]
        toks = [t for t in LIT.findall(code) if is_measurement(t)]
        if not toks:
            continue
        start = n
        while start > 1 and lines[start - 2].strip() != "":
            start -= 1
        block = "\n".join(l for l in lines[start - 1:n] if "//" in l)
        if not CITE.search(block):
            count += 1
            uncited.append("%s:%d  %s   (%s)" % (rel, n, line.strip()[:90], ", ".join(toks)))

print('UNCITED_LITERALS={"count":%d}' % count)
print("\n".join(uncited))
if count > ceiling:
    print("FAIL  %d uncited literal(s) inside the body/seed functions, ceiling %d." % (count, ceiling),
          file=sys.stderr)
    print("      A number a function returns is as much a claim as one a constant holds.", file=sys.stderr)
    raise SystemExit(1)
print("check_cited_authority: literals OK (%d uncited, ceiling %d)" % (count, ceiling))
PY
lrc=$?
cat "$OUT_FILE"
[ "$lrc" -eq 0 ] || exit "$lrc"
n="$(rg -N -o '"count":[0-9]+' "$OUT_FILE" | rg -N -o '[0-9]+' | head -1)"
case "$n" in "" | *[!0-9]*) echo "check_cited_authority: the literal scan produced no count." >&2; exit 2 ;; esac
. "$SCRIPT_DIR/lib_ceiling.sh" 2>/dev/null || true
ceiling_slack "UNCITED_LITERAL_CEILING" "$n" "$LIT_CEILING" 0 "$ROOT" || exit 1
echo "check_cited_authority: OK"
