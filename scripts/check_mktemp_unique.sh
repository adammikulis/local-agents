#!/usr/bin/env bash
# A TEMPORARY FILE TWO LANES SHARE IS NOT A TEMPORARY FILE. BSD mktemp substitutes `XXXXXX` only where it
# ENDS the template; a suffix after it leaves the name literal, so every concurrent run of that gate takes
# one path and deletes the others' file out from under them. Put XXXXXX last and rename.
# EXIT 0 clean · 1 a template whose XXXXXX is not last · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
command -v rg >/dev/null 2>&1 || { echo "check_mktemp_unique: rg absent — a gate that cannot run FAILS." >&2; exit 2; }
[ -d "$ROOT/scripts" ] || { echo "check_mktemp_unique: MISSING $ROOT/scripts" >&2; exit 2; }

# This gate names the shape it bans, so it may not search itself.
hits="$(rg -n --no-heading 'mktemp [^|;&]*XXXXXX[A-Za-z0-9._/-]+' "$ROOT/scripts" \
	-g '!check_mktemp_unique.sh' 2>/dev/null || true)"
if [ -n "$hits" ]; then
	echo "check_mktemp_unique: a template whose XXXXXX is not last names one shared path:" >&2
	printf '%s\n' "$hits" >&2
	echo "                    Put XXXXXX at the end and rename the file afterwards." >&2
	exit 1
fi

# The gate has a subject: templates that ARE well formed.
ok="$(rg -c --no-heading 'mktemp' "$ROOT/scripts" 2>/dev/null | wc -l | tr -d ' ')"
[ "${ok:-0}" -gt 0 ] || { echo "check_mktemp_unique: no mktemp anywhere — the gate has no subject." >&2; exit 2; }
echo "check_mktemp_unique: OK ($ok script(s) make temporary files, every template unique)"
