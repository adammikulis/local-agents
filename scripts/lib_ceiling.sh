#!/usr/bin/env bash
# RISE fails for every caller; SLACK only for the integrator. Lanes do not edit ceiling files.

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_dev_branch.sh"

ceiling_strict() {
	if [ "${LA_CEILING_STRICT:-}" = "1" ]; then printf '1'; return; fi
	if [ "${LA_CEILING_STRICT:-}" = "0" ]; then printf '0'; return; fi
	local root dev here
	root="${1:-$PWD}"
	# An unreadable name takes the STRICT arm: a slack ceiling is loud, a relaxed one is silent.
	dev="$(dev_branch "$root")" || { printf '1'; return; }
	here="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
	if [ "$here" = "$dev" ]; then printf '1'; else printf '0'; fi
}

# A cell-bounded iteration, in every spelling GDScript offers. ONE declaration: the gate that measures it
# and the writer that banks it must ask the same question, and this pattern lived separately in both.
# `range(N)` and `N` are the same loop, so the gate counted one and not the other.
cell_loop_re() {
	local bound='(cc|_cc|cell_count|_cell_count|_f\._cell_count|[a-zA-Z_]*grid\.cell_count)'
	printf '%s' "for [a-zA-Z_][a-zA-Z0-9_]* in (range\()?${bound}\b|while [a-zA-Z_][a-zA-Z0-9_]* < ${bound}\b"
}

# GDScript that DOES something, under <dir>: blank lines and comment-only lines are not logic, and
# counting them prices a comment the same as a statement -- so deleting documentation would pay for
# adding code, and a lane under the ceiling writes denser code to buy lines back. ONE declaration,
# because the gate that measures it and the writer that banks it must ask the same question.
gdscript_code_lines() {
	rg --files -g '*.gd' "$1" 2>/dev/null | tr '\n' '\0' \
		| xargs -0 rg -c -H -N -e '^[[:space:]]*[^[:space:]#]' 2>/dev/null \
		| awk -F: '{s+=$NF} END {print s+0}'
}
