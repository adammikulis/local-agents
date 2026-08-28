#!/usr/bin/env bash
# THE ONE WAY TO RUN `godot --import`. Never bare: concurrent imports across worktrees segfault over the
# same native libraries. The artifacts under .godot/ are a function of the sources scripts/cache_key.sh
# hashes, so a tree already carrying that key imports nothing and a key another tree has imported is
# copied from ${LA_IMPORT_CACHE:-$HOME/.cache/local-agents/import}/<key>.
# Usage: scripts/godot_import.sh [project_dir]. EXIT: godot's own status, or 1 if the lock was refused.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/lib_godot.sh"
. "$SCRIPT_DIR/lib_import.sh"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
. "$ROOT/scripts/lib_godot_lock.sh"

PROJ="${1:-$ROOT}"
[ -f "$PROJ/project.godot" ] || { echo "godot_import: no project.godot under $PROJ" >&2; exit 1; }
CACHE_ROOT="$(la_import_cache_root)"
KEEP_ENTRIES=4

# The key is the content of every source, so a key match PROVES the artifacts were built from this tree.
# `cp -Rp` carries the cache's own mtimes back with them, which la_stale_kernels then reads as every
# kernel being older than its includes and refuses every run afterwards.
la_stamp_imported() {
	[ -d "$PROJ/.godot/imported" ] || return 0
	touch "$PROJ/.godot/imported"/*.res "$PROJ/.godot/imported"/*.md5 2>/dev/null || true
}

KEY="$("$SCRIPT_DIR/cache_key.sh" import --path "$PROJ" 2>/dev/null || echo "")"
if [ -n "$KEY" ] && [ "$(cat "$PROJ/.godot/la_import_key" 2>/dev/null)" = "$KEY" ]; then
	la_stamp_imported
	exit 0
fi

godot_lock || exit 1
trap godot_unlock EXIT

if [ -n "$KEY" ] && [ "$(cat "$CACHE_ROOT/$KEY/.godot/la_import_key" 2>/dev/null)" = "$KEY" ]; then
	rm -rf "$PROJ/.godot.incoming"
	if cp -Rp "$CACHE_ROOT/$KEY/.godot" "$PROJ/.godot.incoming"; then
		rm -rf "$PROJ/.godot"
		mv "$PROJ/.godot.incoming" "$PROJ/.godot"
		la_stamp_imported
		exit 0
	fi
	rm -rf "$PROJ/.godot.incoming"
fi

# Godot reimports a .glsl only when ITS md5 changed and records no dependency on the includes, so an
# edited .glsli rebuilds nothing. A missing artifact always reimports.
while IFS= read -r base; do
	[ -n "$base" ] || continue
	rm -f "$PROJ/.godot/imported/${base}-"*.res "$PROJ/.godot/imported/${base}-"*.md5
done < <(la_stale_kernels "$PROJ")

LA_GODOT_TIMEOUT="${LA_IMPORT_TIMEOUT:-120}" la_godot --headless --path "$PROJ" --import >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"

if [ -n "$KEY" ]; then
	printf '%s\n' "$KEY" > "$PROJ/.godot/la_import_key"
	if [ ! -d "$CACHE_ROOT/$KEY" ]; then
		mkdir -p "$CACHE_ROOT/$KEY"
		if cp -Rp "$PROJ/.godot" "$CACHE_ROOT/$KEY/.godot.tmp"; then
			mv "$CACHE_ROOT/$KEY/.godot.tmp" "$CACHE_ROOT/$KEY/.godot"
		else
			rm -rf "$CACHE_ROOT/$KEY"
		fi
	fi
	# Entries are superseded, never invalidated: what is dropped is only the oldest, and a dropped key
	# costs one import.
	ls -dt "$CACHE_ROOT"/*/ 2>/dev/null | tail -n +$((KEEP_ENTRIES + 1)) | while IFS= read -r old; do
		rm -rf "$old"
	done
fi
exit 0
