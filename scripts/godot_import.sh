#!/usr/bin/env bash
# THE ONE WAY TO RUN `godot --import`. Never call it bare: concurrent imports across worktrees segfault,
# because each loads every GDExtension and they race over the same native libraries.
#
# Usage: scripts/godot_import.sh [project_dir]   (default: the repo this script lives in)
# EXIT: godot's own status, or 1 if the lock could not be taken.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_godot.sh"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_godot_lock.sh"

PROJ="${1:-$ROOT}"
[ -f "$PROJ/project.godot" ] || { echo "godot_import: no project.godot under $PROJ" >&2; exit 1; }

# Godot reimports a .glsl only when ITS md5 changed — it records no dependency on the includes — so an
# edited .glsli rebuilds nothing. Delete the artifacts of every sibling kernel older than an include;
# a missing artifact always reimports.
if [ -d "$PROJ/.godot/imported" ]; then
  while IFS= read -r g; do
    base="$(basename "$g")"
    newest_res="$(ls -t "$PROJ/.godot/imported/${base}-"*.res 2>/dev/null | head -1)"
    [ -n "$newest_res" ] || continue
    for inc in "$(dirname "$g")"/*.glsli; do
      [ -f "$inc" ] || continue
      if [ "$inc" -nt "$newest_res" ]; then
        rm -f "$PROJ/.godot/imported/${base}-"*.res "$PROJ/.godot/imported/${base}-"*.md5
        break
      fi
    done
  done < <(find "$PROJ/addons" -name '*.glsl' -not -path '*/thirdparty/*' 2>/dev/null)
fi

godot_lock || exit 1
trap godot_unlock EXIT
LA_GODOT_TIMEOUT="${LA_IMPORT_TIMEOUT:-120}" la_godot --headless --path "$PROJ" --import >/dev/null 2>&1
exit $?
