#!/usr/bin/env bash
# A COMPILED KERNEL MUST ANSWER FOR ITS #INCLUDES. Godot records no dependency on a .glsli, so an edited
# include leaves SPIR-V that loads, runs and reports normally off the OLD code. lib_import.sh answers by
# content; this holds that answer to the tree, without launching anything.
# EXIT 0 clean · 1 a kernel is stale or unrecorded, an include is dead, a basename collides, or a verdict
# reads an mtime · 2 could not run.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib_require.sh"
. "$ROOT/scripts/lib_import.sh"
require_tool awk
require_tool find

PROJ="${1:-$ROOT}"
[ -f "$PROJ/project.godot" ] || { echo "check_kernel_includes: no project.godot under $PROJ" >&2; exit 2; }
la_md5_file "$PROJ/project.godot" >/dev/null 2>&1 || {
	echo "check_kernel_includes: no md5 tool, so no content verdict exists." >&2; exit 2; }

KERNELS="$(la_kernel_sources "$PROJ")"
n_kernels=$(printf '%s' "$KERNELS" | grep -c . || true)
require_scanned "$n_kernels" 5 "compute kernels"

INCLUDES="$(find "$PROJ" -name '*.glsli' \
	-not -path "$PROJ/.godot/*" -not -path "$PROJ/.claude/*" -not -path "$PROJ/.git/*" \
	-not -path '*/thirdparty/*' 2>/dev/null | sort)"
n_includes=$(printf '%s' "$INCLUDES" | grep -c . || true)
require_scanned "$n_includes" 5 "kernel includes"

fail=0

# The manifest and .godot/imported/<base>-*.res both key on the basename, so two kernels sharing one
# would share a verdict and an artifact glob.
dupes="$(printf '%s\n' "$KERNELS" | sed 's|.*/||' | sort | uniq -d)"
if [ -n "$dupes" ]; then
	echo "FAIL  two compute kernels share a basename, so one verdict answers for both: $dupes" >&2
	fail=1
fi

# Every .glsli some kernel reaches, transitively.
reached=""
while IFS= read -r src; do
	[ -n "$src" ] || continue
	reached="$reached$(la_kernel_includes "$src")
"
done <<EOF
$KERNELS
EOF

while IFS= read -r inc; do
	[ -n "$inc" ] || continue
	case "
$reached" in
		*"
$inc
"*) ;;
		*)
			echo "FAIL  ${inc#$PROJ/} is included by no kernel. A dead include is code nothing compiles." >&2
			fail=1
			;;
	esac
done <<EOF
$INCLUDES
EOF

if [ ! -f "$PROJ/$LA_KERNEL_MANIFEST" ]; then
	echo "check_kernel_includes: $LA_KERNEL_MANIFEST is absent, so nothing records what the artifacts" >&2
	echo "      were built from. Run scripts/godot_import.sh '$PROJ'." >&2
	exit 2
fi

while IFS= read -r src; do
	[ -n "$src" ] || continue
	base="${src##*/}"
	want="$(la_recorded_kernel_hash "$PROJ" "$base")" || {
		echo "FAIL  $base has no recorded include hash, so no artifact answers for its .glsli." >&2
		fail=1
		continue
	}
	have="$(la_kernel_hash "$src")"
	if [ "$want" != "$have" ]; then
		echo "FAIL  $base was compiled from other source than it and its includes now hold" >&2
		echo "      (recorded $want, current $have). Run scripts/godot_import.sh '$PROJ'." >&2
		fail=1
	fi
done <<EOF
$KERNELS
EOF

# The verdict is content. An mtime moves on every checkout and every copied import cache.
if grep -nE '\[ *"?\$[A-Za-z_]+"? -(nt|ot) ' "$ROOT/scripts/lib_import.sh" >/dev/null 2>&1; then
	echo "FAIL  scripts/lib_import.sh decides staleness by mtime again. A checkout moves every mtime" >&2
	echo "      without changing a byte, and a copied import cache moves them the other way." >&2
	fail=1
fi

for consumer in godot_import.sh run_sim_offscreen.sh ensure_worktree_ready.sh; do
	if ! grep -q 'la_stale_kernels' "$ROOT/scripts/$consumer"; then
		echo "FAIL  scripts/$consumer no longer asks which kernels are stale." >&2
		fail=1
	fi
done
if ! grep -q 'la_write_kernel_manifest' "$ROOT/scripts/godot_import.sh"; then
	echo "FAIL  scripts/godot_import.sh no longer records what it built, so every later verdict is blind." >&2
	fail=1
fi

[ "$fail" -eq 0 ] || exit 1
echo "check_kernel_includes: OK ($n_kernels kernels, $n_includes includes, all recorded by content)"
