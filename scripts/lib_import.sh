#!/usr/bin/env bash
# THE ONE ANSWER TO "IS THE COMPILED KERNEL THE ONE ON DISK". Godot writes the source md5 it compiled
# from into a .md5 beside each artifact, and that record is the fact. An mtime stands in only where no
# record exists at all, because a checkout or a copied import cache moves every mtime without changing a
# byte — and a mismatch that an mtime then calls fresh is a dead kernel with a normal-looking report.

la_import_cache_root() { printf '%s' "${LA_IMPORT_CACHE:-$HOME/.cache/local-agents/import}"; }

la_recorded_md5() {  # la_recorded_md5 <src> <record> -> 0 match · 1 MISMATCH · 2 no record, no verdict
	[ -f "$2" ] || return 2
	local want have
	want="$(sed -n 's/^source_md5="\(.*\)"$/\1/p' "$2" | head -1)"
	[ -n "$want" ] || return 2
	if command -v md5sum >/dev/null 2>&1; then
		have="$(md5sum "$1" | cut -d' ' -f1)"
	elif command -v md5 >/dev/null 2>&1; then
		have="$(md5 -q "$1")"
	else
		return 2
	fi
	[ "$want" = "$have" ]
}

# la_stale_kernels <proj> — one basename per kernel whose artifact is missing, compiled from other
# source, or older than an include it pulls in. Godot records no dependency on a .glsli, so a sibling
# include newer than the artifact is the only signal there.
la_stale_kernels() {
	local proj="$1" src base newest inc rc stale
	[ -d "$proj/.godot/imported" ] || return 0
	while IFS= read -r src; do
		base="$(basename "$src")"
		newest="$(ls -t "$proj"/.godot/imported/"$base"-*.res 2>/dev/null | head -1)"
		if [ -z "$newest" ]; then
			printf '%s\n' "$base"
			continue
		fi
		rc=0
		la_recorded_md5 "$src" "${newest%.res}.md5" || rc=$?
		case "$rc" in
			0) stale=0 ;;
			1) stale=1 ;;
			*) if [ "$src" -nt "$newest" ]; then stale=1; else stale=0; fi ;;
		esac
		if [ "$stale" -eq 0 ]; then
			for inc in "$(dirname "$src")"/*.glsli; do
				[ -f "$inc" ] || continue
				if [ "$inc" -nt "$newest" ]; then stale=1; break; fi
			done
		fi
		[ "$stale" -eq 1 ] && printf '%s\n' "$base"
	# SCOPE OR THE GUARD CRIES WOLF: .claude/worktrees holds whole sibling checkouts and thirdparty/
	# vendors llama.cpp's and whisper.cpp's Vulkan shaders, which no sim pass loads.
	done < <(find "$proj" -name '*.glsl' \
		-not -path '*/.godot/*' -not -path '*/.claude/*' -not -path '*/.git/*' \
		-not -path '*/thirdparty/*' 2>/dev/null)
}
