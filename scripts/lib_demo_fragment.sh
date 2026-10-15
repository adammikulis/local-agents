#!/usr/bin/env bash
# A FRAGMENT is a scene another .tscn under addons/local_agents references by path: it belongs to that
# scene, and is neither run nor catalogued on its own. The one declaration of the rule; source it.
#   demo_fragment_parent <repo_root> <scene_rel>
# Prints the first referencing .tscn, repo-relative. Returns 0 fragment · 1 not; exits the calling shell
# 2 when grep could not search.
demo_fragment_parent() {
	local root="$1" rel="$2" refs f rc=0
	# BSD grep with --include reads a missing root as no match.
	[ -d "$root/addons/local_agents" ] || { echo "demo_fragment_parent: no $root/addons/local_agents." >&2; exit 2; }
	refs="$(grep -rlF --include='*.tscn' "path=\"res://$rel\"" "$root/addons/local_agents")" || rc=$?
	if [ "$rc" -gt 1 ]; then
		echo "demo_fragment_parent: grep over $root/addons/local_agents exited $rc." >&2
		exit 2
	fi
	while IFS= read -r f; do
		if [ -n "$f" ] && [ "$f" != "$root/$rel" ]; then
			printf '%s\n' "${f#"$root"/}"
			return 0
		fi
	done <<< "$refs"
	return 1
}

# The scene and every scene it inherits, repo-relative, one per line: follows the root's
# instance=ExtResource.
#   demo_scene_chain <repo_root> <scene_rel>
demo_scene_chain() {
	local root="$1" rel="$2" id
	while [ -n "$rel" ] && [ -f "$root/$rel" ]; do
		printf '%s\n' "$rel"
		id="$(sed -n 's/^\[node name="[^"]*" instance=ExtResource("\([^"]*\)")\]$/\1/p' "$root/$rel" | head -1)"
		[ -n "$id" ] || return 0
		rel="$(grep -F " id=\"$id\"" "$root/$rel" | sed -n 's/.*path="res:\/\/\([^"]*\)".*/\1/p' | head -1)"
	done
}

# A scene honours --run-frames when it, its sibling script, or a scene it inherits builds a
# LocalAgentDemoHarness.
#   demo_has_harness <repo_root> <scene_rel>
demo_has_harness() {
	local f
	grep -qs 'DemoHarness' "$1/${2%.tscn}.gd" && return 0
	while IFS= read -r f; do
		grep -qs 'DemoHarness' "$1/$f" && return 0
	done <<< "$(demo_scene_chain "$1" "$2")"
	return 1
}

# A planet's field needs a compute device, which headless lacks: the voxel world, every scene inheriting
# it, and every scene holding a SPHERE LocalAgentSimWorld run through scripts/run_sim_offscreen.sh.
#   demo_needs_window <repo_root> <scene_rel>
demo_needs_window() {
	demo_window_reason "$1" "$2" >/dev/null
}

# Why the scene needs a window, one line; prints nothing and returns 1 when it does not.
#   demo_window_reason <repo_root> <scene_rel>
demo_window_reason() {
	local f vw='addons/local_agents/game/VoxelWorld.tscn'
	while IFS= read -r f; do
		[ -n "$f" ] || continue
		if [ "$f" = "$vw" ]; then
			if [ "$f" = "$2" ]; then echo "is $vw"; else echo "inherits $vw"; fi
			return 0
		fi
		if demo_holds_sphere_world "$1/$f"; then
			if [ "$f" = "$2" ]; then echo "holds a SPHERE LocalAgentSimWorld"
			else echo "inherits $f, which holds a SPHERE LocalAgentSimWorld"; fi
			return 0
		fi
	done <<< "$(demo_scene_chain "$1" "$2")"
	return 1
}

# A node running sim/SimWorld.gd whose world_type is not FLAT (1). SPHERE is 0 and the default, so a node
# that leaves it unset is one. ` id=` keeps its space: `uid=` ends in `id=`.
#   demo_holds_sphere_world <scene_path>
demo_holds_sphere_world() {
	awk '
		/^\[ext_resource/ && index($0, "path=\"res://addons/local_agents/sim/SimWorld.gd\"") \
				&& match($0, / id="[^"]*"/) { id = substr($0, RSTART + 5, RLENGTH - 6) }
		/^\[/ { if (world && !flat) found = 1; world = 0; flat = 0 }
		id != "" && $0 == "script = ExtResource(\"" id "\")" { world = 1 }
		/^world_type = 1$/ { flat = 1 }
		END { if (world && !flat) found = 1; exit(found ? 0 : 1) }
	' "$1"
}
