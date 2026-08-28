#!/usr/bin/env bash
# A CACHE KEYED BY CONTENT MAY NOT DEPEND ON WHO FILLED IT.
#
# Every path the entry this tree would link hands out points INSIDE that entry, relative to
# CMAKE_CURRENT_LIST_DIR. An entry naming the worktree that filled it dies when that tree is pruned, and
# every other worktree must then refill it. EXIT 0 clean · 1 a path outside the entry · 2 cannot run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3

BUILD="$ROOT/addons/local_agents/gdextensions/localagents/scripts/build_extension.sh"
[ -x "$BUILD" ] || { echo "check_deps_cache_relocatable: MISSING $BUILD." >&2; exit 2; }
KEY="$("$BUILD" --print-deps-key)" || {
	echo "check_deps_cache_relocatable: build_extension.sh could not name this tree's cache key." >&2
	exit 2
}
CACHE_ROOT="${LA_DEPS_CACHE:-$HOME/.cache/local-agents/extdeps}"

python3 - "$CACHE_ROOT/$KEY" <<'PY'
import os, re, sys

entry = sys.argv[1]
if not os.path.isfile(os.path.join(entry, "READY")):
    print(f"check_deps_cache_relocatable: no filled cache entry at {entry}. Build the extension first.",
          file=sys.stderr)
    sys.exit(2)

# A leading '/' preceded by '}' is the tail of ${CMAKE_CURRENT_LIST_DIR}/..., which is what correct looks
# like; preceded by a word character it is part of a token rather than a path.
ABS = re.compile(r"(?<![}\w])/[^\s\"';:()<>]+")

real = os.path.realpath(entry)
scanned = 0
fail = 0
for dirpath, _, names in os.walk(entry):
    for name in names:
        if not (name.endswith(".cmake") or name.endswith(".pc")):
            continue
        path = os.path.join(dirpath, name)
        scanned += 1
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        for hit in sorted(set(ABS.findall(text))):
            resolved = os.path.realpath(hit)
            if resolved == real or resolved.startswith(real + os.sep):
                continue
            print(f"FAIL  {path} names {hit}, which is outside its own cache entry.", file=sys.stderr)
            fail = 1

if scanned == 0:
    print(f"check_deps_cache_relocatable: {entry} carries no .cmake manifest, so it hands out nothing a "
          f"consumer can read. Refill it.", file=sys.stderr)
    sys.exit(2)
if fail:
    print("", file=sys.stderr)
    print("      cmake/deps/CMakeLists.txt stages headers and libraries into the entry and writes every "
          "path in la_deps.cmake as ${CMAKE_CURRENT_LIST_DIR}/... Refill with --clean-deps.",
          file=sys.stderr)
    sys.exit(1)
print(f"check_deps_cache_relocatable: OK ({scanned} manifest(s) in {os.path.basename(entry)}, every path "
      f"inside the entry)")
PY
