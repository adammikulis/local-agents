#!/usr/bin/env bash
# THE SEED'S CONTENT ADDRESS FOR A SLICE A GATE LAUNCHES ITSELF. The walks that seed a slice are a function
# of the tree, the rung and the box, so every launch over one rung and box shares one bake, whatever scene
# or switch it runs with. sim_run.sh addresses its own arms; this is for a gate that calls the scene.
#   la_seal_key world=slice rung=<n> box=<box>   exports LA_SEAL_KEY; a tree that cannot be addressed
#   walks the seed.

LA_SK_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

la_seal_key() {
	local k
	k="$("$LA_SK_SCRIPTS/cache_key.sh" capture --path "$LA_SK_SCRIPTS/.." "$@" 2>/dev/null)" || return 0
	[ -n "$k" ] && export LA_SEAL_KEY="$k"
	return 0
}
