#!/usr/bin/env bash
# THE ONE WAY TO RUN `godot --import`. Never call it bare: concurrent imports across worktrees segfault,
# because each loads every GDExtension and they race over the same native libraries.
#
# Usage: scripts/godot_import.sh [project_dir]   (default: the repo this script lives in)
# EXIT: godot's own status, or 1 if the lock could not be taken.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_godot_lock.sh"

PROJ="${1:-$ROOT}"
[ -f "$PROJ/project.godot" ] || { echo "godot_import: no project.godot under $PROJ" >&2; exit 1; }

godot_lock || exit 1
trap godot_unlock EXIT
timeout "${LA_IMPORT_TIMEOUT:-900}" godot --headless --path "$PROJ" --import >/dev/null 2>&1
exit $?
