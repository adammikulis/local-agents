#!/usr/bin/env bash
# check_model_parameters.sh exempts the authority files, so this holds them instead: a number in
# PhysicalConstants.gd or BodySeeds.gd claims to be a MEASUREMENT, and one with no source is a value
# somebody chose. Counts the uncited, as a ratchet that may only fall. A citation names an author and
# year, a standards body, or a data set, on the constant or in the `##` block above it.
# EXIT 0 at or under the ceiling · 1 over it · 2 the gate could not run.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib_require.sh"
require_tool rg
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CEILING_FILE="$ROOT/docs/UNCITED_AUTHORITY_CEILING"

FILES=(
	"$ROOT/addons/local_agents/sim/material/PhysicalConstants.gd"
	"$ROOT/addons/local_agents/sim/system/BodySeeds.gd"
)
for f in "${FILES[@]}"; do
	[ -f "$f" ] || { echo "check_cited_authority: MISSING $f" >&2; exit 2; }
done
[ -f "$CEILING_FILE" ] || { echo "check_cited_authority: MISSING $CEILING_FILE" >&2; exit 2; }
CEILING="$(rg -N -o '^[0-9]+$' "$CEILING_FILE" | head -1)"
[ -n "$CEILING" ] || { echo "check_cited_authority: $CEILING_FILE holds no bare integer" >&2; exit 2; }

# A source looks like an author-and-year, a standards body, or a named data set.
CITE='[0-9]{4}|CODATA|IUPAC|IAU|NUBASE|HITRAN|NIST|ISA |US Standard|IUGG|exact'
count=0
uncited=""
for f in "${FILES[@]}"; do
	rel="${f#"$ROOT"/}"
	# Constants only: a `const NAME: <type> = <number>` whose right-hand side starts with a digit is a
	# literal measurement. One derived from other constants is held by the expression, not by a source.
	while IFS= read -r line; do
		n="${line%%:*}"
		[ -n "$n" ] || continue
		# The constant's own line, plus the contiguous `##` block immediately above it.
		start="$n"
		while [ "$start" -gt 1 ]; do
			prev="$(sed -n "$((start - 1))p" "$f")"
			case "$prev" in \#\#*) start=$((start - 1)) ;; *) break ;; esac
		done
		block="$(sed -n "${start},${n}p" "$f")"
		if ! printf '%s' "$block" | rg -q -e "$CITE"; then
			count=$((count + 1))
			uncited="$uncited$rel:$n  ${line#*:}"$'\n'
		fi
	done < <(rg -n -e '^const [A-Z_0-9]+: (float|int) = [0-9]' "$f" || true)
done

if [ "$count" -gt "$CEILING" ]; then
	printf '%s' "$uncited" >&2
	echo "FAIL  $count uncited constant(s) in the authority files, ceiling $CEILING." >&2
	echo "      These files are exempt from check_model_parameters.sh because they are MEASUREMENTS." >&2
	echo "      Cite the source beside the value, or the exemption is a hole." >&2
	exit 1
fi
echo "check_cited_authority: OK ($count uncited, ceiling $CEILING)"
exit 0
