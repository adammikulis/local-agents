#!/usr/bin/env bash
# check_model_parameters.sh exempts the authority files, so this holds them instead: a number in
# PhysicalConstants.gd or LABodySystem.cpp claims to be a MEASUREMENT, and one with no source is a value
# somebody chose. Counts the uncited, as a ratchet that may only fall. A citation names an author and
# year, a standards body, or a data set, on the constant or in the comment block above it.
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
)
for f in "${FILES[@]}"; do
	[ -f "$f" ] || { echo "check_cited_authority: MISSING $f" >&2; exit 2; }
done
[ -f "$CEILING_FILE" ] || { echo "check_cited_authority: MISSING $CEILING_FILE" >&2; exit 2; }
CEILING="$(rg -N -o '^[0-9]+$' "$CEILING_FILE" | head -1)"
[ -n "$CEILING" ] || { echo "check_cited_authority: $CEILING_FILE holds no bare integer" >&2; exit 2; }

CEILING="$CEILING" ROOT="$ROOT" python3 - "${FILES[@]}" <<'PY'
import os, re, sys

root, ceiling = os.environ["ROOT"], int(os.environ["CEILING"])
# A source looks like an author-and-year, a standards body, or a named data set.
CITE = re.compile(r"[0-9]{4}|CODATA|IUPAC|IAU|NUBASE|HITRAN|NIST|ISA |US Standard|IUGG|exact")
# LITERALS ONLY, in either language. A right-hand side built from other constants is held by its
# expression, not by a source, and demanding a citation for it was why this gate could not be trusted.
DECL = [re.compile(r"^const [A-Z_0-9]+: (?:float|int) = -?[0-9][0-9._eE+-]*[ \t]*(?:#.*)?$"),
        re.compile(r"^constexpr (?:double|int) [A-Z_0-9]+ = -?[0-9][0-9._eE+-]*;[ \t]*(?://.*)?$")]
COMMENT = re.compile(r"(//|#).*")

count = 0
uncited = []
for path in sys.argv[1:]:
    rel = os.path.relpath(path, root)
    lines = open(path, errors="replace").read().splitlines()
    for n, line in enumerate(lines, 1):
        if not any(rx.match(line) for rx in DECL):
            continue
        # The constant's own line, plus the contiguous comment block immediately above it.
        start = n
        while start > 1 and (lines[start - 2].startswith("##") or lines[start - 2].startswith("//")):
            start -= 1
        # COMMENT TEXT ONLY. Searching the constant's own line let a value cite ITSELF: [0-9]{4} matched
        # the digits in 1.98847e30, so the gate could barely fail.
        block = "\n".join(m.group(0) for m in
                          (COMMENT.search(l) for l in lines[start - 1:n]) if m)
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
print("check_cited_authority: OK (%d uncited, ceiling %d)" % (count, ceiling))
PY
