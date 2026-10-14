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

KEY="$("$SCRIPT_DIR/cache_key.sh" import --path "$PROJ" 2>/dev/null || echo "")"
if [ -n "$KEY" ] && [ "$(cat "$PROJ/.godot/la_import_key" 2>/dev/null)" = "$KEY" ] \
	&& [ -z "$(la_stale_kernels "$PROJ")" ]; then
	exit 0
fi

godot_lock || exit 1
IMPORT_LOG=""
trap 'godot_unlock; [ -z "$IMPORT_LOG" ] || rm -f "$IMPORT_LOG"' EXIT

if [ -n "$KEY" ] && [ "$(cat "$CACHE_ROOT/$KEY/.godot/la_import_key" 2>/dev/null)" = "$KEY" ]; then
	rm -rf "$PROJ/.godot.incoming"
	if cp -Rp "$CACHE_ROOT/$KEY/.godot" "$PROJ/.godot.incoming"; then
		rm -rf "$PROJ/.godot"
		mv "$PROJ/.godot.incoming" "$PROJ/.godot"
		[ -z "$(la_stale_kernels "$PROJ")" ] && exit 0
		# The entry is missing a kernel artifact. Every tree taking that key would copy the same hole.
		rm -rf "${CACHE_ROOT:?}/${KEY:?}"
	else
		rm -rf "$PROJ/.godot.incoming"
	fi
fi

# Godot reimports a .glsl only when ITS md5 changed and records no dependency on the includes, so an
# edited .glsli rebuilds nothing until its artifacts are gone. Only the kernels that reach the changed
# include lose theirs; la_kernel_hash names them.
while IFS= read -r base; do
	[ -n "$base" ] || continue
	rm -f "$PROJ/.godot/imported/${base}-"*.res "$PROJ/.godot/imported/${base}-"*.md5
done < <(la_stale_kernels "$PROJ")

IMPORT_LOG="$(mktemp "${TMPDIR:-/tmp}/la_import.XXXXXX")" || exit 2
LA_GODOT_TIMEOUT="${LA_IMPORT_TIMEOUT:-120}" la_godot --headless --path "$PROJ" --import >"$IMPORT_LOG" 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
	echo "godot_import: engine import failed (exit $rc):" >&2
	cat "$IMPORT_LOG" >&2
	exit "$rc"
fi

la_write_kernel_manifest "$PROJ" || { echo "godot_import: could not record the kernel include hashes." >&2; exit 1; }

# Godot exits 0 having reimported nothing, so the .import file can name a .res that was never written:
# load() then returns null and the GPU field is silently dead. Never key or cache that.
left="$(la_stale_kernels "$PROJ")"
if [ -n "$left" ]; then
	echo "godot_import: godot exited 0 and these kernels still have no artifact:" >&2
	printf '  %s\n' $left >&2
	exit 1
fi

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
