#!/usr/bin/env bash
# GODOTCPP_API_VERSION must equal the engine on PATH, and the PINNED godot-cpp must ship that
# extension_api. The pin decides what a clean fetch produces, so the pin is what this asks.
#
# EXIT 0 pass · 1 the declaration diverged · 2 the gate could not run, never a silent pass.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh" 2>/dev/null || true
. "$ROOT/scripts/lib_godot.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_capture.sh"
la_examined "$(basename "$0")" || exit $?
require_tool rg

EXT="$ROOT/addons/local_agents/gdextensions/localagents"
CM="$EXT/cmake/deps/CMakeLists.txt"
FETCH="$EXT/scripts/fetch_dependencies.sh"
for f in "$CM" "$FETCH"; do
	[ -f "$f" ] || { echo "check_api_version: MISSING $f" >&2; exit 2; }
done

declared="$(rg -N -o -r '$1' '^set\(GODOTCPP_API_VERSION "([0-9]+\.[0-9]+)"' "$CM" | head -1)"
[ -n "$declared" ] || { echo "check_api_version: CMakeLists.txt declares no GODOTCPP_API_VERSION." >&2; exit 2; }

pin="$(rg -N -o -r '$1' '^GODOT_CPP_REF="\$\{GODOT_CPP_REF:-([0-9a-f]{40})\}"' "$FETCH" | head -1)"
[ -n "$pin" ] || { echo "check_api_version: fetch_dependencies.sh carries no 40-char godot-cpp pin." >&2; exit 2; }

GODOT="${GODOT:-godot}"
command -v "$GODOT" >/dev/null 2>&1 || { echo "check_api_version: no '$GODOT' on PATH." >&2; exit 2; }
if la_cap_dir >/dev/null; then
	engine="$(la_headless engine_version | rg -N -o -r '$1' '^ENGINE_VERSION=([0-9]+\.[0-9]+)' | head -1)"
else
	engine="$(la_godot --version 2>/dev/null | rg -N -o -r '$1' '^([0-9]+\.[0-9]+)' | head -1)"
fi
[ -n "$engine" ] || { echo "check_api_version: could not read the engine version." >&2; exit 2; }

fail=0
if [ "$declared" != "$engine" ]; then
	echo "check_api_version: CMakeLists.txt binds against $declared, the engine on PATH is $engine." >&2
	echo "                   The library would be built against an API the engine does not speak." >&2
	fail=1
fi

# The pin is the authority on what a CLEAN fetch produces. A checkout on disk may be older than the pin,
# which is exactly how the declared version came to name an extension_api the pin does carry, off a
# checkout that did not.
CP="$EXT/thirdparty/godot-cpp"
api="$CP/gdextension/extension_api-${declared//./-}.json"
# Arm one above judged the declaration against the engine with no checkout needed. Arm two needs the
# pin on disk; a tree without it reports the arm UNCHECKED by name and never claims it passed.
head_sha=""
[ -d "$CP/.git" ] && head_sha="$(git -C "$CP" rev-parse HEAD 2>/dev/null)"
if [ "$head_sha" != "$pin" ]; then
	echo "check_api_version: NOT CHECKED — no godot-cpp at the pin ($pin); on disk: ${head_sha:-absent}." >&2
	echo "                   The engine arm was judged. Run fetch_dependencies.sh to judge the pin." >&2
	echo "API_VERSION={\"declared\":\"$declared\",\"engine\":\"$engine\",\"pin_checked\":false,\"failures\":$fail}"
	exit "$fail"
fi
if [ ! -f "$api" ]; then
	echo "check_api_version: the pinned godot-cpp ships no extension_api-${declared//./-}.json." >&2
	echo "                   It carries: $(ls "$CP/gdextension" | rg -N -o 'extension_api-[0-9-]+' | tr '\n' ' ')" >&2
	fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "check_api_version: OK (binds $declared, engine $engine, pinned godot-cpp ships extension_api-${declared//./-}.json)"
