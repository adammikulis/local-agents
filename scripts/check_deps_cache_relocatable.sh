#!/usr/bin/env bash
# A CACHE KEYED BY CONTENT MAY NOT DEPEND ON WHO FILLED IT.
#
# Every path a cache entry hands out points INSIDE that entry, relative to CMAKE_CURRENT_LIST_DIR. An
# entry naming the worktree that filled it dies when that tree is pruned, and every other worktree must
# then refill it. EXIT 0 clean · 1 an entry names a path outside itself · 2 the gate could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
require_tool python3

CACHE_ROOT="${LA_DEPS_CACHE:-$HOME/.cache/local-agents/extdeps}"
python3 - "$CACHE_ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]
if not os.path.isdir(root):
    print(f"check_deps_cache_relocatable: MISSING {root}. Build the extension first.", file=sys.stderr)
    sys.exit(2)

entries = [os.path.join(root, d) for d in sorted(os.listdir(root))
           if os.path.isdir(os.path.join(root, d))]
if not entries:
    print(f"check_deps_cache_relocatable: no cache entry under {root}. Build the extension first.",
          file=sys.stderr)
    sys.exit(2)

# A leading '/' preceded by '}' is the tail of ${CMAKE_CURRENT_LIST_DIR}/..., which is what correct
# looks like; preceded by a word character it is part of a token, not a path.
ABS = re.compile(r"(?<![}\w])/[^\s\"';:()<>]+")

scanned = 0
fail = 0
for entry in entries:
    real = os.path.realpath(entry)
    manifest_root = os.path.join(entry, "la_deps.cmake")
    if not os.path.isfile(manifest_root):
        print(f"check_deps_cache_relocatable: {entry} carries no la_deps.cmake, so it hands out "
              f"nothing a consumer can read. Refill it.", file=sys.stderr)
        sys.exit(2)
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
                print(f"FAIL  {path} names {hit}, which is outside its own cache entry.",
                      file=sys.stderr)
                fail = 1

if scanned == 0:
    print("check_deps_cache_relocatable: examined no manifest. A gate that examines nothing is not a "
          "gate.", file=sys.stderr)
    sys.exit(2)
if fail:
    print("", file=sys.stderr)
    print("      cmake/deps/CMakeLists.txt stages headers and libraries into the entry and writes every "
          "path in la_deps.cmake as ${CMAKE_CURRENT_LIST_DIR}/... Refill the entry from a build.",
          file=sys.stderr)
    sys.exit(1)
print(f"check_deps_cache_relocatable: OK ({len(entries)} entries, {scanned} manifests, every path "
      f"inside its own entry)")
PY
