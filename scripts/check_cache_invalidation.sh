#!/usr/bin/env bash
# EVERY CACHE HERE IS INVALIDATED BY CONTENT. Three arms over scripts/cache_key.sh: a file appearing must
# move the key, the same file merely touched must not, and removing it must restore it. Plus each cache's
# script must still ask for a key — one that stopped asking reuses whatever it finds.
# EXIT 0 clean · 1 a key is time-sensitive, content-blind or unconsulted · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
KEYGEN="$ROOT/scripts/cache_key.sh"
[ -x "$KEYGEN" ] || { echo "check_cache_invalidation: no scripts/cache_key.sh to examine." >&2; exit 2; }

PROBE="$ROOT/addons/local_agents/.la_cache_probe"
rm -f "$PROBE"
trap 'rm -f "$PROBE"' EXIT

GODOT_BIN="$(command -v "${GODOT:-godot}" 2>/dev/null || echo "")"
[ -n "$GODOT_BIN" ] || { echo "check_cache_invalidation: no godot on PATH to hash." >&2; exit 2; }
ENGINE="engine=$(md5 -q "$GODOT_BIN" 2>/dev/null || md5sum "$GODOT_BIN" | cut -d" " -f1)"
key() { "$KEYGEN" "$1" --path "$ROOT" "$ENGINE" 2>/dev/null; }

fail=0
for kind in import scan capture; do
	k0="$(key "$kind")"
	[ -n "$k0" ] || { echo "check_cache_invalidation: cache_key.sh '$kind' produced nothing." >&2; exit 2; }

	printf 'one\n' > "$PROBE"
	k1="$(key "$kind")"
	if [ "$k1" = "$k0" ]; then
		echo "FAIL  the '$kind' key is blind to a new source file, so a cache built without it is reused." >&2
		fail=1
	fi

	touch -t 203001010000 "$PROBE"
	k2="$(key "$kind")"
	if [ "$k2" != "$k1" ]; then
		echo "FAIL  the '$kind' key moved when only an mtime moved. Every checkout would miss every cache," >&2
		echo "      and the reason a cache exists is that the content did not change." >&2
		fail=1
	fi

	printf 'two\n' > "$PROBE"
	k3="$(key "$kind")"
	if [ "$k3" = "$k1" ]; then
		echo "FAIL  the '$kind' key did not move when a source's CONTENT changed." >&2
		fail=1
	fi

	rm -f "$PROBE"
	k4="$(key "$kind")"
	if [ "$k4" != "$k0" ]; then
		echo "FAIL  the '$kind' key does not return to its original value once the tree does." >&2
		fail=1
	fi
done

# A CAPTURE IS A RUN, AND scripts/ DECIDES WHAT THE RUN IS. A key blind to the launcher and the arm
# hands a lint a capture some other code produced.
SPROBE="$ROOT/scripts/.la_cache_probe"
rm -f "$SPROBE"
trap 'rm -f "$PROBE" "$SPROBE"' EXIT
base="$(key capture)"
printf 'one\n' > "$SPROBE"
if [ "$(key capture)" = "$base" ]; then
	echo "FAIL  the 'capture' key is blind to a change under scripts/, so a capture taken by other code" >&2
	echo "      is reused as this one's reading." >&2
	fail=1
fi
rm -f "$SPROBE"

for consumer in godot_import.sh editor_scan.sh lint_capture.sh; do
	if ! grep -qE 'cache_key\.sh" +(import|scan|capture)\b' "$ROOT/scripts/$consumer"; then
		echo "FAIL  scripts/$consumer no longer asks for a content key, so whatever it reuses is unguarded." >&2
		fail=1
	fi
done

[ "$fail" -eq 0 ] || exit 1
echo "check_cache_invalidation: OK (import, scan and capture keys follow content and ignore mtime)"
