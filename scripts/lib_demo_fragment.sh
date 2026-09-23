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
