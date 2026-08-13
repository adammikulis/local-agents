#!/usr/bin/env bash
# RISE fails for every caller; SLACK only for the integrator. Lanes do not edit ceiling files.

ceiling_strict() {
	if [ "${LA_CEILING_STRICT:-}" = "1" ]; then printf '1'; return; fi
	if [ "${LA_CEILING_STRICT:-}" = "0" ]; then printf '0'; return; fi
	local root dev here
	root="${1:-$PWD}"
	dev="$(rg -N -o -e '\*\*The current development branch is `[^`]+`' "$root/CLAUDE.md" 2>/dev/null \
		| head -1 | sed -E 's/.*`([^`]+)`.*/\1/')"
	[ -n "$dev" ] || dev="0.4-dev"
	here="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")"
	if [ "$here" = "$dev" ]; then printf '1'; else printf '0'; fi
}
