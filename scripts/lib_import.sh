#!/usr/bin/env bash
# THE ONE ANSWER TO "IS THE COMPILED KERNEL THE ONE ON DISK", BY CONTENT ONLY. Godot writes the source md5
# it compiled from into a .md5 beside each artifact and records NOTHING about the .glsli that source
# #includes, so an edited include rebuilds nothing. la_kernel_hash closes that: one digest over the kernel
# and the transitive closure of its includes, recorded at import in .godot/la_kernel_includes.
# An mtime answers "when"; a checkout or a copied import cache moves every mtime without changing a byte.

la_import_cache_root() { printf '%s' "${LA_IMPORT_CACHE:-$HOME/.cache/local-agents/import}"; }

LA_KERNEL_MANIFEST=".godot/la_kernel_includes"

la_md5_file() {
	if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1
	elif command -v md5 >/dev/null 2>&1; then md5 -q "$1"
	else return 2
	fi
}

la_md5_stdin() {
	if command -v md5sum >/dev/null 2>&1; then md5sum | cut -d' ' -f1
	elif command -v md5 >/dev/null 2>&1; then md5 -q
	else return 2
	fi
}

la_recorded_md5() {  # la_recorded_md5 <src> <record> -> 0 match · 1 MISMATCH · 2 no record, no verdict
	[ -f "$2" ] || return 2
	local want have
	want="$(sed -n 's/^source_md5="\(.*\)"$/\1/p' "$2" | head -1)"
	[ -n "$want" ] || return 2
	have="$(la_md5_file "$1")" || return 2
	[ "$want" = "$have" ]
}

# SCOPE OR THE GUARD CRIES WOLF: .claude/worktrees holds whole sibling checkouts and thirdparty/ vendors
# llama.cpp's and whisper.cpp's Vulkan shaders, which no sim pass loads.
la_kernel_sources() {  # la_kernel_sources <proj> -> every first-party compute kernel, one path per line
	find "$1" -name '*.glsl' \
		-not -path '*/.godot/*' -not -path '*/.claude/*' -not -path '*/.git/*' \
		-not -path '*/thirdparty/*' 2>/dev/null | sort
}

la_include_names() { sed -n 's|^[[:space:]]*#include[[:space:]]*"\([^"]*\)".*|\1|p' "$1"; }

la_kernel_includes() {  # la_kernel_includes <src> -> the includes it reaches, transitively, sorted
	local src="$1" dir name path pending seen more nl
	nl=$'\n'
	dir="$(dirname "$src")"
	seen=""
	pending="$(la_include_names "$src")"
	[ -n "$pending" ] && pending="$pending$nl"
	while [ -n "$pending" ]; do
		name="${pending%%"$nl"*}"
		pending="${pending#*"$nl"}"
		[ -n "$name" ] || continue
		path="$dir/$name"
		case "$nl$seen" in *"$nl$path$nl"*) continue ;; esac
		[ -f "$path" ] || continue
		seen="$seen$path$nl"
		more="$(la_include_names "$path")"
		[ -n "$more" ] && pending="$pending$more$nl"
	done
	printf '%s' "$seen" | sort
}

la_kernel_hash() {  # la_kernel_hash <src> -> one digest over the kernel and every include it reaches
	local src="$1" inc acc
	acc="$(la_md5_file "$src")" || return 2
	while IFS= read -r inc; do
		[ -n "$inc" ] || continue
		acc="$acc ${inc##*/}=$(la_md5_file "$inc")"
	done < <(la_kernel_includes "$src")
	printf '%s' "$acc" | la_md5_stdin
}

la_recorded_kernel_hash() {  # la_recorded_kernel_hash <proj> <basename> -> the hash recorded at import
	local manifest="$1/$LA_KERNEL_MANIFEST"
	[ -f "$manifest" ] || return 1
	awk -v k="$2" '$1 == k { print $2; hit = 1 } END { exit !hit }' "$manifest"
}

la_write_kernel_manifest() {  # la_write_kernel_manifest <proj> — record what the artifacts were built from
	local proj="$1" src tmp
	tmp="$proj/$LA_KERNEL_MANIFEST.tmp"
	mkdir -p "$(dirname "$tmp")" || return 1
	: > "$tmp" || return 1
	while IFS= read -r src; do
		[ -n "$src" ] || continue
		printf '%s %s\n' "${src##*/}" "$(la_kernel_hash "$src")" >> "$tmp"
	done < <(la_kernel_sources "$proj")
	mv -f "$tmp" "$proj/$LA_KERNEL_MANIFEST"
}

la_stale_kernels() {  # la_stale_kernels <proj> — one basename per kernel the artifacts do not answer for
	local proj="$1" src base newest rc want
	[ -d "$proj/.godot/imported" ] || return 0
	while IFS= read -r src; do
		base="${src##*/}"
		# NO SIDECAR, NO LOADER. `*.import` is gitignored, so a fresh worktree has the compiled .res and
		# no mapping to it: load() returns null and the pass is silently dead.
		if [ ! -f "$src.import" ]; then
			printf '%s\n' "$base"
			continue
		fi
		newest="$(ls -t "$proj"/.godot/imported/"$base"-*.res 2>/dev/null | head -1)"
		if [ -z "$newest" ]; then
			printf '%s\n' "$base"
			continue
		fi
		rc=0
		la_recorded_md5 "$src" "${newest%.res}.md5" || rc=$?
		if [ "$rc" -ne 0 ]; then
			printf '%s\n' "$base"
			continue
		fi
		want="$(la_recorded_kernel_hash "$proj" "$base")" || { printf '%s\n' "$base"; continue; }
		[ "$want" = "$(la_kernel_hash "$src")" ] || printf '%s\n' "$base"
	done < <(la_kernel_sources "$proj")
}
