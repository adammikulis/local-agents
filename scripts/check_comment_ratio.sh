#!/usr/bin/env bash
# A CHANGE MAY NOT ADD MORE COMMENT THAN CODE. Density gates measure a file; this measures the diff, which
# is where prose actually arrives.
#
# Default subject is the staged change (pre-commit). Pass a ref to measure a branch instead.
#
# EXIT 0 clean · 1 more comment than code · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
require_tool git

BASE="${1:-}"
if [ -n "$BASE" ]; then
	diff_cmd=(git -C "$ROOT" diff "$BASE...HEAD" --)
else
	diff_cmd=(git -C "$ROOT" diff --cached --)
fi
# generated.glsli is machine-written; its header is not a person explaining themselves.
PATHS=(':(glob)**/*.sh' ':(glob)**/*.gd' ':(glob)**/*.glsl' ':(glob)**/*.glsli' ':(glob)**/*.py'
	':(exclude,glob)**/generated.glsli' ':(exclude,glob)**/generated.gdshaderinc')

d="$("${diff_cmd[@]}" "${PATHS[@]}" 2>/dev/null || true)"
if [ -z "$d" ]; then
	echo "check_comment_ratio: OK (no source change)"
	exit 0
fi

# PER FILE. An aggregate hides the file that is all prose behind a file that is all code.
bad="$(printf '%s\n' "$d" | awk '
	/^\+\+\+ b\// { if (f != "" ) print c, k, f; f = substr($0, 7); c = 0; k = 0; next }
	/^\+\+\+/ { next }
	/^\+[ \t]*(#|\/\/)[ \t]*(SOAK|claim|shellcheck|!)/ { k++; next }
	/^\+[ \t]*(#|\/\/)/ { c++; next }
	/^\+[ \t]*$/ { next }
	/^\+/ { k++ }
	END { if (f != "") print c, k, f }
' | awk '$1 > $2 { print }')"

if [ -n "$bad" ]; then
	echo "check_comment_ratio: a change may not explain itself at greater length than it acts." >&2
	printf '%s\n' "$bad" | awk '{ printf "  %-52s %s comment / %s code\n", $3, $1, $2 }' >&2
	exit 1
fi
echo "check_comment_ratio: OK (no file adds more comment than code)"
