#!/usr/bin/env bash
# WHO IS ALLOWED TO TIGHTEN A RATCHET, AND WHY IT IS NOT EVERY LANE.
#
# A ceiling is one number in one tracked file, and "lower it in the commit that earned it" means every
# concurrent lane edits that file. Measured over one session: four of six merge conflicts were ceiling
# files and nothing else. A counter every lane must write is a serialization bottleneck, which is the
# thing this repository splits files to avoid -- and it was introduced by the gate that enforces it.
#
# So the ratchet has two arms and they belong to different people:
#   RISE  -- a lane made the tree worse. Every caller fails on this, always.
#   SLACK -- the tree improved and the number was not written down. Only the INTEGRATOR fails on this,
#            because only the integrator knows the count after all lanes have merged. A lane's count is
#            measured against a tree that is about to change under it.
#
# STRICT is on when the checkout is on the dev branch (integration) or LA_CEILING_STRICT=1 (CI).
# `scripts/integrate.sh` writes the ceilings itself, so the number is never hand-carried.

# Prints "1" when the slack arm must fire, "0" when only the rise arm may.
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
