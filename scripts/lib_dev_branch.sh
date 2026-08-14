#!/usr/bin/env bash
# THE DEV BRANCH IS NAMED ONCE, IN CLAUDE.md. Every script reads it from there.
# No literal default: a default is what lets a gate measure a branch that no longer exists and say nothing.
# Prints the name, or nothing and returns 1.

dev_branch() {
	local root name
	root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
	name="$(sed -n 's/.*\*\*The current development branch is `\([^`]*\)`.*/\1/p' "$root/CLAUDE.md" 2>/dev/null | head -1)"
	if [ -z "$name" ]; then
		echo "lib_dev_branch: $root/CLAUDE.md does not name the current development branch." >&2
		return 1
	fi
	printf '%s' "$name"
}
