#!/usr/bin/env bash
# ONE MEMOISED FILE DIGEST, for a file too big to re-read on every key. The ANSWER is the content's; the
# MEMO is keyed on the stat signature, so a byte that changes moves the mtime and the memo misses. A hit
# costs a stat and a read. A cache that cannot be written still answers, by computing.

la_hash_cache_root() { printf '%s' "${LA_HASH_CACHE:-$HOME/.cache/local-agents/filehash}"; }

la_md5_of() {
	if command -v md5 >/dev/null 2>&1; then md5 -q "$1"
	elif command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1
	else return 2
	fi
}

la_md5_of_stdin() {
	if command -v md5 >/dev/null 2>&1; then md5 -q
	elif command -v md5sum >/dev/null 2>&1; then md5sum | cut -d' ' -f1
	else return 2
	fi
}

la_md5_memo() {
	local f="$1" sig root entry digest
	[ -f "$f" ] || return 2
	sig="$(stat -f '%z %m %i' "$f" 2>/dev/null || stat -c '%s %Y %i' "$f" 2>/dev/null)"
	if [ -z "$sig" ]; then
		la_md5_of "$f"
		return $?
	fi
	root="$(la_hash_cache_root)"
	entry="$root/$(printf '%s %s' "$f" "$sig" | la_md5_of_stdin)"
	if [ -s "$entry" ]; then
		cat "$entry"
		return 0
	fi
	digest="$(la_md5_of "$f")" || return 2
	if mkdir -p "$root" 2>/dev/null; then
		printf '%s\n' "$digest" > "$entry.$$" 2>/dev/null && mv -f "$entry.$$" "$entry" 2>/dev/null
	fi
	printf '%s\n' "$digest"
}
